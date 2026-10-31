"""Exercise real console shutdown in isolated, hidden Windows subprocesses."""

import ctypes
from ctypes import wintypes
from pathlib import Path
import queue
import subprocess
import sys
import threading


def check_shutdown(executable: Path, mode: str, event: int) -> None:
    startup = subprocess.STARTUPINFO()
    startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0  # SW_HIDE: the fixture owns a private console.
    with subprocess.Popen(
        [str(executable), "--windows-shutdown-child", mode],
        creationflags=subprocess.CREATE_NEW_CONSOLE,
        startupinfo=startup,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ) as child:
        lines = queue.Queue()
        stderr = []
        reader = threading.Thread(
            target=lambda: lines.put(child.stdout.readline()), daemon=True
        )
        logger = threading.Thread(
            target=lambda: stderr.append(child.stderr.read()), daemon=True
        )
        reader.start()
        logger.start()
        attached = False
        try:
            ready = lines.get(timeout=5)
            if ready != "READY\n":
                raise AssertionError(f"{mode}: fixture failed before readiness")
            if not kernel.AttachConsole(child.pid):
                raise ctypes.WinError(ctypes.get_last_error())
            attached = True
            # Broadcast only within the fixture's private console. Handle both
            # events here; the NULL-handler ignore flag covers only Ctrl+C
            # and would also be inherited by subsequently created fixtures.
            if not kernel.SetConsoleCtrlHandler(ignore_console_event, True):
                raise ctypes.WinError(ctypes.get_last_error())
            if not kernel.GenerateConsoleCtrlEvent(event, 0):
                raise ctypes.WinError(ctypes.get_last_error())
            returncode = child.wait(timeout=3)
            logger.join(timeout=1)
            log = "".join(stderr)
            if returncode != 0 or "event=shutdown_requested" not in log:
                raise AssertionError(
                    f"{mode}, event={event}: exit={returncode}\n{log}"
                )
        except BaseException:
            # Never leave a failed fixture running or wait indefinitely in
            # Popen.__exit__. Forced termination is cleanup, not a test pass.
            if child.poll() is None:
                child.kill()
                child.wait(timeout=3)
            logger.join(timeout=1)
            print("".join(stderr), file=sys.stderr)
            raise
        finally:
            if attached:
                kernel.FreeConsole()
            reader.join(timeout=1)
            logger.join(timeout=1)


if __name__ == "__main__":
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.AttachConsole.argtypes = [wintypes.DWORD]
    kernel.AttachConsole.restype = wintypes.BOOL
    kernel.FreeConsole.argtypes = []
    kernel.FreeConsole.restype = wintypes.BOOL
    kernel.SetConsoleCtrlHandler.argtypes = [ctypes.c_void_p, wintypes.BOOL]
    kernel.SetConsoleCtrlHandler.restype = wintypes.BOOL
    kernel.GenerateConsoleCtrlEvent.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel.GenerateConsoleCtrlEvent.restype = wintypes.BOOL

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.DWORD)
    def ignore_console_event(event):
        return event in (0, 1)

    # Detach only this short-lived test harness, never the invoking shell.
    kernel.FreeConsole()
    if not kernel.SetConsoleCtrlHandler(None, False):
        raise ctypes.WinError(ctypes.get_last_error())
    executable = Path(sys.argv[1]).resolve()
    for event in (0, 1):  # CTRL_C_EVENT, CTRL_BREAK_EVENT
        for mode in ("idle", "active", "partial"):
            check_shutdown(executable, mode, event)
    print("Windows console shutdown checks passed (six subprocesses).")
