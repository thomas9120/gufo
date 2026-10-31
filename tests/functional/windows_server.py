"""Hidden private consoles for native Windows functional server lifecycles."""

import ctypes
from ctypes import wintypes
import subprocess


def launch_options():
    startup = subprocess.STARTUPINFO()
    startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    return {"creationflags": subprocess.CREATE_NEW_CONSOLE, "startupinfo": startup}


def stop(process, timeout):
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
    def ignore(event):
        return event in (0, 1)

    attached = False
    try:
        # Detach this harness only, then address the server's private console.
        kernel.FreeConsole()
        if process.poll() is not None:
            return
        if not kernel.AttachConsole(process.pid):
            if process.poll() is not None:
                return
            raise ctypes.WinError(ctypes.get_last_error())
        attached = True
        if not kernel.SetConsoleCtrlHandler(ignore, True):
            raise ctypes.WinError(ctypes.get_last_error())
        if not kernel.GenerateConsoleCtrlEvent(1, 0):  # CTRL_BREAK_EVENT
            raise ctypes.WinError(ctypes.get_last_error())
        process.wait(timeout=timeout)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        if attached:
            kernel.SetConsoleCtrlHandler(ignore, False)
            kernel.FreeConsole()
