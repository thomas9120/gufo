# Windows integration status

Stage one, the transport/host increments, and persistence foundations in the
[integration plan](plans/windows-compatibility.md) build the current official
engine's **CPU CLI and selected host/server checks** natively on Windows x64.
This is an integration milestone, not a supported Windows inference release.
Native HIP builds, Windows GPU-budget admission, pinned-memory/transfer checks,
and selected Flash-Next live checks now pass. The Windows queue-policy boundary
is implemented, and an optional local browser launcher is included. Wider
runtime qualification remains pending.
Windows CPU CI is implemented; hosted results and the bounded-fixture correction
are recorded below. The component disk cache is enabled on private local NTFS
directories with a [rebuildable-cache contract](#windows-component-disk-cache).
The older continuation disk store remains disabled. GGUF digest caching and
private content tracing are enabled.

For every upstream merge, review the [Windows compatibility contracts](WINDOWS-COMPATIBILITY.md)
and their implementation/regression checks.

## Windows installer

[`Gufo-Setup.cmd`](https://github.com/thomas9120/gufo-windows/releases/latest/download/Gufo-Setup.cmd)
is the guided installer distributed with each release. It fetches
`windows-main` from `thomas9120/gufo-windows`, renders the plan reported by
`tools/windows/setup.ps1`, runs the guided setup with the chosen build jobs, and
then offers Update, Repair, and Uninstall. The install folder is, in order:
`-InstallDir`; the checkout containing the installer when it runs from one; the
folder saved by an earlier run, while it still holds a Gufo checkout; otherwise
`%USERPROFILE%\Gufo`. The menu shows which of these applied, and **F** changes
it. A checkout picked only because the installer ran from it is never saved, so
running a development copy does not redirect later release installs. When the
browser launcher starts an engine from a different checkout, the menu says so
and offers to switch to it. Shared dependencies stay under
`%LOCALAPPDATA%\Gufo\dependencies` and logs under `%LOCALAPPDATA%\Gufo\logs`.

Release assets pair the launcher with `Gufo-Setup.ps1`; the launcher verifies the
script's SHA-256 before running it. Running the launcher from a checkout uses
`tools/installer/Gufo-Setup.ps1` directly. After a successful setup the installer
keeps a copy under `%LOCALAPPDATA%\Gufo\installer` with a **Gufo Setup** Start
Menu entry, so Update, Repair, and Uninstall stay reachable.

The installer needs a console with virtual-terminal support (Windows Terminal is
the Windows 11 default). Without it, the installer falls back to a line-mode
prompt. Command-line use:

```powershell
.\Gufo-Setup.cmd                          # full-screen installer
.\Gufo-Setup.cmd -Action install -Yes     # unattended; no prompts
.\Gufo-Setup.cmd -Action repair -Yes
.\Gufo-Setup.cmd -Action update -Yes
.\Gufo-Setup.cmd -Action uninstall -Yes
.\Gufo-Setup.cmd -Plain                   # numbered prompt, line output
```

`-InstallDir`, `-Jobs`, `-Rocm`, `-Vcpkg`, and `-NoShortcut` match the Advanced
screen; `-ColorMode` and `-AsciiGlyphs` adjust the display for terminals with
limited colour or font support. Advanced settings persist in
`%LOCALAPPDATA%\Gufo\installer.json`; an unreleased installer from a checkout
uses `installer.dev.json` instead. With arguments, the launcher never waits
at a pause prompt, and exit code 2 means the run was declined or cancelled.

Uninstall does not pre-select an install folder that has uncommitted or
untracked files, unpublished commits on any local branch, stashes, or the
installer itself (for example a development checkout); line-mode uninstall
skips such folders. Folders containing model files cannot be removed through
the installer: move the models outside the checkout first. If Git metadata or
Git itself is unavailable, the folder is kept because models cannot be checked.
In smaller terminals, use Page Up/Page Down to inspect the uninstall list;
the confirmation and controls stay visible.

The installer runs `tools/windows/setup.ps1` directly, the script that
`setup-windows.bat` wraps, so a failed build never waits at the batch file's
press-any-key prompt. Setup keeps its own transcript under the checkout's
`build/` folder; the installer records the same output in its log.

## Prerequisites and build

For guided source setup on Windows 11 Strix Halo, use the
[installer](#windows-installer) or run [`setup-windows.bat`](../setup-windows.bat)
inside a checkout. Setup detects existing tools, previews missing prerequisites,
asks before installation, builds `windows-gpu`, checks GPU startup, and
prepares/opens the browser launcher. Saved GUI settings and the installer's
choices are preserved. This is a developer source build with the same
qualification and redistribution limits described below.

To preview without installing or building, or reuse a nondefault vcpkg checkout:

```powershell
./setup-windows.bat -CheckOnly
./setup-windows.bat -Vcpkg C:\path\to\vcpkg -NoLaunch
```

`tools/windows/setup.ps1 -CheckOnly -PlanJson plan.json` also writes the
machine-readable plan the installer renders. Neither form installs or builds
anything.

The setup script also accepts `-Rocm`, `-Jobs`, and `-Yes` (accept the displayed
setup plan). Logs and reusable tool selections are saved under `build/`.
For manual setup or CPU-only builds, follow the commands below.

Use Windows 11 x64, Visual Studio C++ Build Tools with the Windows SDK, CMake 3.21
or newer, Ninja, Python, Git, and a bootstrapped vcpkg checkout. The initial
compiler for the HIP integration is the clang distributed with TheRock 10.0.0,
extracted under `C:\TheRock\build`. CPU builds can also use standalone LLVM
23.1.2 through `-CompilerBin`; neither CPU build needs ROCm runtime libraries or
a GPU. The pinned dependencies in the root `vcpkg.json` are installed into this
worktree's `build/vcpkg_installed`; the build does not reuse the fork's binaries.

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File tools/windows/check.ps1 -Vcpkg C:\vcpkg
powershell -ExecutionPolicy Bypass -File tools/windows/build.ps1 -Vcpkg C:\vcpkg
ctest --preset windows-cpu
./build/windows-cpu/gufo.exe --version
./build/windows-cpu/gufo.exe --help
```

Override `-Rocm`, `-CompilerBin`, `-Vcpkg`, or `-Ninja` for your local installation.
The default compiler directory remains `-Rocm` plus `lib/llvm/bin`. `-Jobs`
controls build parallelism and defaults to four. For focused iteration, supply
`-Target gguf_reader_test`, for example. The default `windows-cpu` build preset
builds the CLI, its `gufo-server.exe` copy, and the selected host/server tests.
Use this bounded preset on Windows; other test targets include Linux-specific
harnesses which have not yet been ported. The existing Linux presets remain
unchanged.

For the native HIP development build with TheRock 10.0.0:

```powershell
./tools/windows/build.ps1 -Preset windows-gpu -Vcpkg C:\vcpkg
./build/windows-gpu/gufo.exe probe
```

The script stages TheRock runtime DLLs and the BLAS kernel libraries beside the
executables. Windows kernel-bench profiler markers are disabled when TheRock
does not provide rocprofiler-sdk; Linux still requires that dependency. This
build remains a development milestone pending the qualification below.

The script imports the MSVC headers and libraries, invokes CMake, and stages
runtime DLLs beside the executables. CMake retains the official
`GUFO_RELEASE_VERSION` and `GUFO_REVISION` definitions, and creates the server
copy without requiring symlink privileges. Run the executable from the build
directory distribution; installation/redistributable packaging is not yet
qualified. The locally copied VS LLVM OpenMP DLL comes from `debug_nonredist`
and is for developer use only, not public binary redistribution. Standalone
LLVM builds instead use the OpenMP library and DLL shipped with that compiler.

## Local browser launcher

The [launcher](../tools/gui/README.md) is a separate Python process that starts
one `gufo serve llm` child. It does not load a model until **Start** is pressed
and does not change the engine's runtime dependencies. After building a Windows
target, double-click [launch-gui.bat](../launch-gui.bat), or run:

```powershell
.\launch-gui.bat -Port 8090
.\launch-gui.bat -NoBrowser
```

The first run creates `build/gui-env` and installs the pinned Flask/Waitress
requirements. The launcher opens `http://127.0.0.1:8090`; its API binds to
localhost only. Select the executable (defaults to this checkout's
`build/windows-gpu/gufo.exe`, then `build/windows-cpu/gufo.exe` or
`build/release/gufo.exe`), models, and options, then save a preset. Settings live
in `%LOCALAPPDATA%\Gufo\launcher.json`; the API and launcher ports must differ.
Stop and Exit terminate the owned Gufo process tree; closing the browser does
not.

The launcher's disk-cache controls pass the engine's `--cache-disk*` flags;
Flash-Next supports the [Windows cache contract](#windows-component-disk-cache).
Options
saved by the older Windows-fork launcher that this engine does not expose
(`debug_tool_calls`, `mtp_draft_vocab`, and `prompt_lookup`) are ignored when an
existing settings file is loaded.

Run the focused launcher checks with its environment:

```powershell
.\build\gui-env\Scripts\python.exe -m unittest discover -s tests/tools -p "gui_*_test.py"
npm install --prefix build/gui-test-js --no-save --package-lock=false jsdom@26.1.0
node --experimental-vm-modules --test tests/tools/gui_dom_test.mjs tests/tools/gui_runtime_dom_test.mjs
```

These tests use fake child processes and local HTTP fixtures; they do not load a
model or require a GPU.

## Windows CPU CI

The separate [Windows workflow](../.github/workflows/windows-cpu.yml) runs the
bounded `windows-cpu` build and all 16 checks on `windows-2025`, on pull requests
and pushes to `main`, `windows-main` or `feat/windows-cpu-compat`, and through manual dispatch.
It retains build/configuration logs and CTest results; it does not publish
executables. The Linux CI workflow also runs on `windows-main` (an intentional
fork-only trigger addition in `.github/workflows/ci.yml`), so a sync candidate
gets the Linux contract gate from hosted CI.

[setup-ci.ps1](../tools/windows/setup-ci.ps1) downloads the official
[LLVM 23.1.2 release](https://github.com/llvm/llvm-project/releases/tag/llvmorg-23.1.2)
and verifies the Windows MSVC archive's SHA-256 before extraction. It bootstraps
an isolated vcpkg checkout at the root manifest's `builtin-baseline`. The job
caches the pinned compiler and vcpkg binary archives, leaving CMake build trees
and installed dependencies fresh. vcpkg's ABI keys account for toolchain changes;
the logs record compiler/build-tool and hosted-image versions. Visual Studio
headers/libraries and the Windows SDK come from the hosted image.

To reproduce that setup locally with the prerequisites above:

```powershell
$tools = & ./tools/windows/setup-ci.ps1
& ./tools/windows/build.ps1 -CompilerBin $tools.CompilerBin -Vcpkg $tools.Vcpkg
ctest --preset windows-cpu --no-tests=error
```

The helper's downloads and checkout stay under ignored `build/windows-ci`.
When changing compilers in an existing build, use `-CMakeArgs @('--fresh')`
with CMake 3.24 or newer to reset the compiler probes and preset variables.
This is a CPU contract gate; GPU/model correctness, numerical quality, and
performance require the later native HIP qualification.

Locally validated on 2026-10-12, building on `9d897f15`, with LLVM 23.1.2,
MSVC 14.51.36231, Windows SDK 10.0.26100.0, CMake 4.4.0, Python 3.14.6, and
PowerShell 7.6.6:

- Verified download, selective compiler extraction, isolated vcpkg bootstrap
  at the manifest baseline, and subsequent reuse of the extracted compiler.
- Successful native CPU build and all 14 checks passing in 17.26 seconds.
  The retained JUnit report records zero failures, disabled tests, or skips;
  the staged OpenMP DLL matches the compiler's runtime.
- actionlint 1.7.12, PowerShell syntax checks, and shared documentation and
  dependency checks pass.

These results use the local host's VS/SDK and existing manifest dependencies.
Linux, GPU/model, and performance qualification are not claimed by this increment.

The [hosted run at `afb05c1c`](https://github.com/thomas9120/gufo-adapted/actions/runs/38328358834/job/115072200657)
successfully configured and built, and passed 14 of 15 native checks.
`win32_compat_test` reached its 30-second timeout. Its four-byte write beyond
4 GiB used a regular Windows file, requiring allocation/zeroing of the gap and
a full-file flush. The original test emitted no phase markers, so the hosted
log cannot establish the exact stalled operation.

The fixture now uses `FSCTL_SET_SPARSE`, retaining the same production
`pwrite`/`pread`/`fsync` calls, 64-bit offset, logical-size and identity checks.
It also checks zero-filled hole reads and physical allocation of at most 1 MiB.
Flushed phase markers identify future stalls. No production filesystem behavior
or CTest timeout changed. Focused repeats pass locally in 0.03–0.07 seconds;
the full bounded suite passes. The
[hosted correction run at `2e3f9a91`](https://github.com/thomas9120/gufo-adapted/actions/runs/38329300470)
passes all 15 checks in 12.95 seconds, including the compatibility fixture.
Logs are retained under `build/windows-ci/compat-timeout-20261012-204754`, including
the original hosted artifacts and local build/CTest/format results.

## Scope and boundaries

Windows build wiring is in `cmake/Windows.cmake`. The CPU-only
`gufo_posix_compat` target supplies the shadow headers and Win32 implementations
to Gufo-owned targets; it links only Winsock, PSAPI, and Advapi32 security APIs,
with no HIP or DXGI
dependency. Linux does not include the module. Linux WebP discovery, Nix,
compiler flags, model framing, algorithms, and the disk format are retained.
WebP is found through the upstream `pkg_check_modules` line, using vcpkg's
`libwebp.pc` and its host `pkgconf`. Deferred calls in the module adjust root
targets after they exist instead of editing upstream lines: they exclude the
Linux cache fault library from the default build, disable its test and
install a `gufo-server.exe` copy. Linux's `check-pr` target is configured but
not built on Windows.

Two portable C++ changes are needed to compile the current official code:
the JSON `size_t` constructor must tolerate Windows' identical
`unsigned long long` type, and GGUF hashing uses aligned C++ allocation instead
of `std::aligned_alloc`, which is absent from the Windows CRT. Small socket
option, descriptor-type, and fatal-signal adaptations initially made the CPU
CLI link; server transport validation is recorded below.

Both checkpoint-store implementations reject Windows initialization before
touching their cache directories. Private GGUF digest caching and content
tracing are now qualified by the focused CPU checks below. The filesystem shim
creates protected ACLs, verifies ownership/privacy, and uses native handles for
child-file operations. Unsupported flushes fail explicitly. Checkpoint layout
durability, store-level recovery, and their native fault harnesses are deferred;
the isolated filesystem checks do not establish those guarantees. The initial
Windows port will run without disk checkpoint persistence: RAM continuation
reuse remains in scope, but restarting the engine requires prompt recomputation.
Conversation history kept by a client or GUI is independent of these stores.

Native HIP configuration is enabled by the `windows-gpu` preset; the live checks
below use that build. Requirements such as TheRock, WDDM memory budgeting, and
pinned transfers remain development milestones, not a redistributable release.

## Stage-one validation

Validated on 2026-10-12 against official base
`8d4e1a2b74c94752b9b16b1dda153cbf52638443` with:

- TheRock 10.0.0, clang 23.0.0, LLD, MSVC 14.51.36231, Windows SDK 10.0.26100.0.
- CMake 4.4.0, Ninja, Python 3.14, and the manifest's pinned vcpkg baseline.
- Successful native CPU configuration and build; `gufo.exe` and its server
  copy run with their colocated DLLs.
- All nine `windows-cpu` checks pass: version, help, argument parser, JSON,
  JSON constraints, GGUF reader, GGUF identity, Windows compatibility, and the
  cache dependency boundary (including the shim's transitive links).
- Compatibility coverage includes spawning/waiting with spaced arguments,
  independent exclusive locks, offsets beyond 4 GiB, UTF-8/spaced directory
  names, directory-descriptor ownership, no-replace rename, file identity,
  file flush, explicit directory-flush failure, and disk-store rejection.
- GGUF checks cover mapped reads and full/parallel hashing, including edits
  with restored timestamps. Windows verifies that a mapped file cannot be
  shrunk; the Linux shrink-induced prefetch-failure test is retained on Linux.
- The shared formatting check passes with clang-format 21.1.8.

These stage-one checks did not qualify HTTP/WebSocket, disk-cache recovery,
Linux builds, GPU inference, performance, or numerical model behavior.

## Stage-two server transport validation

Validated on 2026-10-12 with the same native toolchain, building on stage-one
commit `bc7f8c64`. The bounded `windows-cpu` preset now runs **12 checks**, adding
`http_server_test`, `audio_websocket_test`, and `win32_server_shutdown_test`.
All 12 pass, along with the shared formatting, documentation, and dependency
checks. The CLI also rejects `--trace` before loading a model and creates no file.
The server checks use real local TCP connections and mock generation/audio
services; no GPU or model is needed.

The implementation retains native Winsock handles, maps receive/send errors,
uses millisecond socket timeouts, and closes sockets through Winsock. The
listener remains nonblocking; accepted Windows connections are restored to
blocking mode because they inherit the listener's properties, as described by
[Microsoft's accept documentation](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-accept).
The listening address is exclusive on Windows. Response cleanup drains briefly
before closing, with no network wait under the worker mutex.

Server stop cancels pending socket I/O and joins workers; each worker retains
its handle until its I/O finishes. Native experiments and the subprocess tests demonstrated that
Winsock `shutdown` alone does not interrupt a pending receive.
[CancelIoEx](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelioex)
requests cancellation; the worker still owns the handle until its I/O finishes.
WebSocket readers observe an explicit server-stop token between bounded poll
waits, while retaining the idle limit for sessions receiving no input or output.

Coverage includes:

- Existing HTTP authorization, request parsing/framing, API responses, SSE
  heartbeats, deferred headers, streaming failures, and device-loss tests.
- Split HTTP heads/bodies, graceful and reset disconnects during buffered and
  streaming generation, and cancellation on server stop.
- Stop during incomplete HTTP requests and a blocked response write, without
  requiring the peer to send, read, or disconnect.
- Existing audio WebSocket handshakes, buffered/fragmented frames, ping/pong,
  streamed output, protocol-error close replies, and peer-close cancellation.
- Silent-session idle expiry, continued output keeping a listener alive,
  delayed consumption of a close reply with unread input, and local stop during
  incomplete frames and active audio work.
- Real Ctrl+C and Ctrl+Break events in six isolated hidden-console subprocesses:
  each event stops an idle listener, active generation, and an incomplete request
  through normal cleanup. Embedded `run(false)` keeps caller-owned handlers.
- Explicit Winsock timeout/error mapping, occupied-port rejection, and content
  trace refusal without creating a file.

Console-window closure, logoff, and forced process termination do not provide a
graceful-cleanup guarantee. Persistent-cache crash recovery is a separate
increment. The Linux test paths are
retained, including their signal subprocess tests, but a Linux build remains
pending: the toolchain is not installed in this host's WSL environment. Windows
CPU CI and live GPU/model correctness and timing qualification remain pending.

## Stage-two host integration validation

Validated on 2026-10-12 with the same native toolchain, building on transport
commit `7a2ab5bb`. All **13** bounded `windows-cpu` checks pass, including the new
`win32_host_test`. Shared formatting, documentation, and dependency checks pass.
The native test covers host queries, snapshot budget/ceiling arithmetic, live
memory log fields, explicit Linux-style fixtures, diagnostic verdicts, and cache
path selection with Unicode/spaced paths and empty/missing environment values.

The adaptations use the fork at
`ab4d98189a6d8103fce29d2537e4113da3da2420` as their reference. Windows reports
CPU names/vendor through CPUID and counts actual physical cores and NUMA nodes
through
[GetLogicalProcessorInformationEx](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getlogicalprocessorinformationex),
rather than assuming two threads per core. Logical processor counts span all
processor groups. Explicit fixture roots retain the existing `/proc` parser;
missing fixtures do not fall back to the live Windows host.

Host inventory, HTTP logs, and RAM snapshot admission now use native memory
queries. The process RSS field reports its Windows working set. Total/available
RAM comes from
[GlobalMemoryStatusEx](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-globalmemorystatusex).
It is OS-visible physical RAM, not installed RAM or a WDDM device budget.
Admission retains the existing half-available automatic budget and headroom
ceiling. Linux CMA/cgroup logic remains on Linux. Windows Job Object memory
limits and actual HIP allocations have not been qualified.

Live CLI JSON and human diagnostics were checked against Windows CIM on this
host: Ryzen AI MAX+ 395, 16 physical cores, 32 logical processors, one NUMA node,
Windows `10.0.26300`, and `33,981,009,920` OS-visible physical bytes. CPU-only
diagnostics report GPU/Windows driver compatibility as `unknown`, with GPU and
toolchain warnings; platform-only diagnostics pass. Compiler metadata identifies
the actual Clang build. They no longer inherit Linux's hard-coded GPU, amdgpu,
GCC, or ROCm values. Memory hardware type/unified classification is unavailable;
`memoryType` is `unknown`, `isUnified` remains false, and the unqueried Linux
`freeBytes` field is zero with its limitation identified in `source`.

The shared default-cache selector uses `XDG_CACHE_HOME/gufo`, then on Windows
`LOCALAPPDATA/gufo`, then `HOME/.cache/gufo`. With no usable root it returns no
path. Windows reads the native wide environment, preserving Unicode profile
paths. At that increment both stores and persistent GGUF identity caching
remained disabled before any directory creation. Opt-in continuation cache
directories remain caller-selected. The persistence-foundation increment below
qualifies the independent identity cache and tracing. Linux build verification,
Windows CI, HIP, and the GUI were pending at that increment.

## Persistence foundations and unresolved cache contract

This section records the initial deferral. The component store now uses the
[Windows contract below](#windows-component-disk-cache); the older store remains
guarded.

Validated on 2026-10-12 on local NTFS with the same native toolchain, building on
host-integration commit `e20cc86a`. That increment's bounded preset contains
**14 checks**, including `win32_filesystem_test`. All pass. This increment qualifies private
file operations, tracing, and identity caching; it does **not** complete the
checkpoint-persistence increment.

`compat/win32/filesystem.cpp` isolates native handle-relative operations. It
uses
[NtCreateFile](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile)
with the parent directory handle for `openat`/`mkdirat`; directory enumeration
also uses the handle. Rename, no-replace publication, unlink, and `fstatat` keep
that identity after the directory is renamed and its old path is replaced.
Replacement permits existing readers to finish with the old file. No-follow
opens reject intermediate and final reparse points. Native junction tests do
not require symbolic-link privileges, which are unavailable on this host.

New `0600`/`0700` objects receive a protected DACL granting access only to the
process's token user SID. Existing ownership and ACLs are inspected; synthetic
uid zero means that SID, while foreign/unknown ownership fails cache checks.
Mode bits are conservative privacy indicators, not complete Unix permission
emulation. `chmod`/`fchmod` implement private `0600`/`0700` ACLs and reject other
modes; they are no longer no-ops. Unknown or broader ACL shapes fail privacy
checks. Tests inspect the actual ACL and demonstrate access denial with a
restricted token. NTFS ChangeTime is required rather than falling back to
mtime, so restoring mtime cannot conceal edits from cached GGUF identities.

GGUF digest caching uses the unchanged upstream format, full-hash invalidation,
and malformed-digest fallback. Native cache files and directories are private.
`--trace` creates private files and rejects unprotected existing files, reparse
points, directories, and files with multiple hard links before recording data.
The HTTP trace content/authorization/streaming tests now run on Windows too.
These facilities are separate from both disabled checkpoint stores.

Filesystem tests force process death after payload write, file flush, rename,
and directory flush, then reopen and verify the namespace and complete payload.
Failure injection covers write/flush failure and errors before or after rename
and unlink take effect. Fault controls exist only in `BUILD_TESTING` builds;
production compilation of the filesystem/shim was also checked with those
controls absent. Process termination does not model power loss, and these are
operation tests, not checkpoint-store recovery tests. Linux's ELF-wrap/fork
harnesses remain unchanged.

Native experiments show
[FlushFileBuffers](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers)
succeeds on writable directory handles here and rejects a read-only handle.
The shim requests directory write access rather than ignoring a failed flush.
However, the new common store syncs every ancestor up to the filesystem root
when creating its layout. This unprivileged process cannot obtain that access
to `C:\Users` or `C:\`, although it can flush its own directories. A successful
rename or a process-crash test cannot establish the missing ancestor durability.

The selected contract preserves upstream guarantees: both checkpoint
guards stay intact. The user deferred disk checkpoint persistence to reduce
maintenance when merging upstream updates. It does not block native HIP or GUI
integration. A future port requires resolving the Windows
durability contract, qualifying the store algorithms and privacy checks, and
adding native restart/reclamation/corruption/failure tests. A weaker Windows
power-loss contract has not been selected or implemented. No Linux build,
live GPU/model cache behavior, numerical quality, or speed qualification is
claimed by these CPU checks.

## Windows component disk cache

The current component store used by Flash-Next supports disk continuation
caching on **local NTFS**, without administrator privileges. It retains the
upstream v2 format, single-server ownership lock, immutable dependency sharing,
bounded streaming, budget accounting and checksum validation. The older
`ContinuationDiskStore` remains disabled on Windows.

Select a new cache folder, for example `%LOCALAPPDATA%\Gufo\flash-next-cache`.
Gufo creates missing directories with protected token-user-only ACLs. Existing
roots, managed subdirectories and the ownership lock must already be private;
broader or unprotected ACLs are rejected rather than silently rewritten.
The path must not contain `..`, reparse points or directory junctions. FAT,
exFAT, ReFS and network paths are outside this implementation's supported scope.
Use a separate directory per running server. The staging size option remains
ignored by component caches; a fixed 1 MiB buffer streams larger checkpoints.

This is a **rebuildable cache**, not a power-loss durability guarantee. Payloads
and manifests are flushed before publication, and managed directories are
flushed after namespace changes. Windows does not flush profile/volume ancestors:
ordinary users need not obtain write access to `C:\Users` or `C:\`. A power
failure can lose checkpoints or layout entries. Startup validates manifest
checksums, geometry and dependency sizes; restore verifies payload checksums
and file identity before the destination becomes executable. Invalid entries
are rejected and prompts are recomputed. Actual I/O failures remain errors;
the shim does not pretend an unsuccessful flush succeeded.

`win32_disk_store_test` exercises the store itself with native subprocesses:
publication termination boundaries, restart/orphan recovery, exclusive ownership,
streamed writes, shared chunks and pinned retirement, missing/truncated/corrupt
dependencies, hard links, ACL rejection and injected write/flush/rename/unlink
failures. The filesystem checks also exercise cache-root creation through real
junctions and private Unicode paths. These tests do not simulate physical power
loss. They are part of the bounded `windows-cpu` preset.

### October 21 component-cache validation

Local NTFS, Radeon 8060S (`gfx1151`), driver `32.0.32015.7029`, TheRock 10.0.0,
AMD Clang 23, MSVC 14.51.36231 and Windows SDK 10.0.26100.0. The release candidate
and an unchanged `git archive` of base `2dd7e5f7` use matching compiler/build
settings and pinned dependencies. Source and binary hashes, commands, individual
request measurements and every timing control are archived under
`pr65-disk-cache/qualification/` in the [evidence archive](WINDOWS-UPSTREAM-SYNC.md#evidence-archive).

- All **16 bounded native CPU checks pass**, including the new store test's 36
  publication subprocess scenarios (18 abrupt terminations), 24 injected
  publication/retirement failure cases, private ACLs and independent ownership.
  All 80 functional-runner unit checks pass with Python UTF-8 mode. The shared
  C++ formatting and documentation checks pass.
- The supplied four-shard `UD-Q4_K_XL` Flash-Next model passes AR and shared-Q8
  MTP startup/restart checks. MTP also loads the BF16 vision projector. A cold
  2,294-token prompt has zero reuse; a process restart restores 2,287 tokens
  from disk and prefills the remaining seven, reproducing the exact reply.
- Both modes pass the eight `cache` subcases: cancelled text, reasoning/tools,
  legacy tool history and growing checkpoint spacing, followed by disk restores
  after restart. Both publish at 2,447 and 6,278 tokens, skip 18 checkpoints below
  the minimum step and restore a 3,043-token shared boundary. MTP actually
  proposes 197 drafts and accepts 163 across these requests; AR proposes zero.
- The opt-in `cache_startup.py --case corrupt` check damages **372 payload files**
  while preserving their sizes and manifests. MTP rejects the damaged cache,
  recomputes all 2,294 prompt tokens and returns the exact cold reply. It then
  publishes a replacement, restarts, and restores 2,287 tokens from that replacement.
- The existing 64-token GPU sequential/batched prefill numerical checks pass in
  both modes: finite logits, reference winner rank 1, reported RMSE 0.53, cosine
  0.99 and maximum error 2.75, within unchanged envelopes. Standard pp2048/tg128
  spots retain one observation per point. Both binaries/modes return the same
  128-token hash; MTP proposes/accepts 109/58 drafts in each binary.

Long-context correctness passes at 32K configured context, two slots and an
8 GiB RAM budget in both modes, including exact cached replay and cancellation.
Per-request/phase timing remains **inconclusive and unqualified** at the unchanged
5% and 3 ms limits. Focused alternating controls retain every observation;
unchanged-main controls reproduce RAM snapshot and scheduling flags. For example,
the first AR snapshot measures 47.56 ms on the initial base, 64.85 ms on the
candidate and 63.64 ms on the unchanged base control. A 37.19-second MTP candidate
startup outlier returns to 27.66 seconds in its control, against base observations
of 27.24 and 27.45 seconds. These RAM-only histories do not enter the changed
disk operations. No speedup or general timing qualification is claimed.

Focused controls also stage both executables at the same path with identical
runtime DLLs. The unchanged AR base's cached Responses replay varies from
44.25 to 57.22 ms client TTFT, reproducing the original flag. MTP's same-path
cached replay still flags: base/candidate client TTFT is 44.81/56.25 ms and
42.70/64.44 ms in the two pairs; earlier full-history base observations are
62.98 and 55.41 ms. This repeated latency flag remains unresolved and
**unqualified**, with all individual results retained rather than averaged.

Live qualification here covers Flash-Next AR/MTP on local NTFS. Qwen27B,
other filesystems, physical power-loss behavior, full-model F32 quality and
Linux build/GPU checks remain outside this local validation. The initial
relative-executable test launch failed before engine startup; its failed report
is archived as `pr65-disk-cache/qualification/startup-ar`, and the corrected
absolute-path run is `startup-ar-2`.

## Initial native HIP live inference

On 2026-10-12, the native `windows-gpu` build based on `3137e712` plus the HIP
build-wiring changes passed a bounded live smoke check on the Radeon 8060S
(`gfx1151`). The compiler is TheRock 10.0.0; `probe` reports runtime
`7.15.26333` and 107.87 GiB device memory. The preset uses RelWithDebInfo with
assertions enabled. This evidence covers one model on this host.

Artifacts supplied locally were the four-part
`Qwen3.8-Flash-Next-UD-Q4_K_XL` GGUF, `mmproj-BF16.gguf`, and
`mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf`. With one session, a 4096-token context,
thinking off, and disk cache off:

- AR loaded in 23.839 seconds and MTP in 35.166 seconds. Health and model
  discovery succeeded, advertising text and image inputs.
- Both modes returned the expected buffered answer `42`, streamed answer `10`
  with a terminal SSE marker, and conversation follow-up `50`.
- Both follow-ups reported a RAM cache hit, 28 reused prompt tokens, and only
  29 new prefill tokens. AR reported zero drafts. Each MTP request actually ran
  one draft round, proposing three tokens and accepting one.
- An AR image request correctly identified a generated solid-red PNG as `Red`.

Requests, responses, per-request timings, server logs, and smoke scripts are
retained locally under `build/windows-gpu/live-flash-20261012-184954`. The test
servers were stopped after use. These short checks establish live execution,
streaming, a RAM restore, and one vision example; they do not establish numerical
quality, a speed comparison, long-context/cancellation behavior, allocation
pressure, or support for other models. The GPU-budget increment below addresses
WDDM admission. Pinned-memory contracts, broader model-owned checks, and the final
Linux/Windows qualification remain required. Disk checkpoint persistence remains
excluded from the initial port.

## Windows GPU-budget admission

The GPU-only [platform helper](../src/core/platform/device_memory.hpp) adapts
the fork's budget query against the current official source. On an integrated
Windows GPU it matches the calling thread's current HIP device to DXGI by LUID,
then queries the process's local and non-local segment budgets through
[QueryVideoMemoryInfo](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/nf-dxgi1_4-idxgiadapter3-queryvideomemoryinfo).
Available bytes are the sum of each segment's nonnegative `Budget - CurrentUsage`.
Total bytes are the summed OS budgets, not physical installed memory. These are
admission limits; allocation can still fail as budgets and usage change.

Adapter discovery is shared under a mutex, with an independent COM reference
for each query. Switching the current device cannot leave a caller using the
previous device's adapter. Budget values are refreshed on every query. TheRock
10.0.0 supplies a valid LUID but a zero node mask on this `gfx1151` APU; that known
single-node case uses node zero. Unknown zero/multiple-node masks and discrete
GPUs retain the HIP fallback. Failed/partial DXGI queries and overflowing sums
leave the complete HIP result intact. HIP errors return before DXGI is consulted;
null output pointers retain the runtime's partial-query behavior.

Nine production admission sites use the helper: the Qwen, DeepSeek, and
Flash-Next resource claims; DeepSeek's FP16-cache and managed-KV decisions;
Flash-Next's snapshot allocator; the shared weight-placement and
session/scratch allocators in `managed_alloc.hpp`; and the component cache's
pinned-host heap check. The loader's informational `hipMemGetInfo` query
remains raw HIP for comparison. Linux's helper directly forwards to
`hipMemGetInfo`. The Windows CMake module links DXGI only into the HIP build;
the CPU shim and common cache retain their reviewed dependencies.

Validation on 2026-10-12 uses the same TheRock/VS/SDK host as the initial HIP
record, based on `1e4c4333` plus this increment:

- The native HIP engine rebuild and the new GPU-only
  `win32_device_memory_test` pass. Its independent DXGI oracle matches the active
  HIP adapter before/after a 512 MiB allocation, after free, and on another thread.
  Synthetic checks cover reduced/exhausted budgets, failure of either segment,
  partial results, and overflow; real null-output calls match HIP. This host has
  one HIP device, so actual switching between multiple GPUs is not qualified.
- All 14 Windows CPU checks pass in 17.50 seconds. The cache dependency boundary,
  shared C++ formatting, and dependency-record checks pass. Two profiler no-op
  functions from the prior HIP increment were formatted to satisfy the shared
  check; their behavior is unchanged.
- Selected live cancellation/replay checks pass in AR and MTP, including repeated
  fresh-server runs. Both restore 317 cached tokens and prefill only 34 new tokens;
  the third turn retains the growing prefix. Seeded replay output and cache work
  match the earlier binary. AR performs zero drafts; interrupted MTP generations
  actually propose and accept nine tokens over two draft rounds.

Per-request/phase comparisons retain the repository's 5% and 3 ms limits.
Early comparisons using different executable names flagged a warm MTP replay's
wall/server duration. A temporary trace found no budget query during that replay;
the tracing code was removed. Alternating the binaries at the same executable
path did not reproduce that apparent slowdown: the warm replay's server duration
was 89.3-91.7 ms for the control and 85.5 ms for both candidate observations.
This does not establish the cause of the earlier difference. Other timings vary,
so overall AR/MTP performance evidence remains **inconclusive and unqualified**.
Earlier flags, repeated observations, and unchanged-binary controls are retained;
no timing margins were widened and no speed qualification is claimed.

The retained evidence is under `build/windows-gpu/wddm-20261012-190713`, including
binary identities, build/CTest logs, server commands, model file metadata,
request/phase timings, and every timing comparison and control. The earlier
binary's SHA-256 matches the initial smoke record, and its recorded build patch
matches `1e4c4333`. The selected live check uses `tests/functional/continuation.py`
with `content-preserve0-sampled0`, one session, context 4096, and a fixed 2 GiB RAM
cache. All test servers were stopped. Disk restart is excluded. Performance
qualification and the wider
Linux/model checks remain pending; these checks do not establish
a physical-memory-pressure or allocation-failure contract.

### Small BIOS carveouts

With the BIOS carveout at its minimum (0.5 GB) and the rest of memory left to
WDDM, HIP's `hipMemGetInfo` reports only about 75% of the shared budget. Weight
placement used to compare against that figure, chose managed memory for a large
model, and the load failed because Windows lacks HIP managed-memory support.
Weight placement now uses the DXGI budget, like the other admission sites.

[PR #91](https://github.com/thomas9120/gufo-windows/pull/91) reports two more
failures on such a carveout, both from the AMD PAL driver's small local heap
(about 335 MiB): small allocations through PAL's suballocator, and hardware
queues for concurrent upload streams. Two HIP runtime variables, set before
starting Gufo, address them:

```powershell
$env:GPU_MAX_SUBALLOC_SIZE = "0"   # place small allocations in shared memory
$env:GPU_MAX_HW_QUEUES = "2"       # optional: cap hardware queues
```

Gufo does not set either automatically, and neither has been qualified on a
small carveout in this fork. A 64–96 GB carveout does not need them. Automatic
detection is tracked in [the TODO](todo.md).

## Windows pinned backing and transfers

TheRock 10.0.0 on the local Radeon 8060S (`gfx1151`) passes the native
[`win32_pinned_transfer_test`](../tests/platform/win32_pinned_transfer_test.cpp).
The increment adds only Windows test wiring and a test; the production backing,
staging, transfer and model code is unchanged.

The test covers explicit `hipHostMallocCoherent` flags and zeroed pages,
precommitted block accounting, exhaustion/reuse, pins retaining physical memory
and accounting after pool destruction, and four concurrent borrowers. Ledger
reserve/convert failures exercise rollback, including failure after backing
allocation. Staging retains its allocation after the allocator and original
owner release it; all ledger charges return to zero after owners drain.

Real H2D/D2H transfers preserve a nonuniform payload with unaligned endpoints,
4,093-byte pieces, a partial tail and untouched guard bytes. The test also
covers stream/event lease exhaustion and reuse, repeated waits, sealed streams,
zero-byte copies, independently progressing streams with one pending host
callback, and a completion surviving pool destruction. Snapshot transfers
drain before releasing a borrowed stream and preserve row padding with different
source/destination pitches. The common cache dependency boundary passes.

Build and run the focused checks after the HIP development build above:

```powershell
./tools/windows/build.ps1 -Preset windows-gpu -Target win32_pinned_transfer_test -Vcpkg C:\vcpkg
ctest --test-dir build/windows-gpu -R '^win32_pinned_transfer_test$' --output-on-failure
./tools/windows/build.ps1 -Preset windows-gpu -Target qwen38_flash_next_continuation_probe -Vcpkg C:\vcpkg
./build/windows-gpu/qwen38_flash_next_continuation_probe.exe --model PATH --mtp-model MTP_PATH --mode ar --context 4096 --sessions 2 --backing-gib 1 --round-trip
./build/windows-gpu/qwen38_flash_next_continuation_probe.exe --model PATH --mtp-model MTP_PATH --mode mtp --context 4096 --sessions 2 --backing-gib 1 --round-trip
```

The Linux `cache_backing_test` and its ELF `--wrap` hooks are unchanged. The
native test does not observe every HIP allocation/copy call or inject HIP
allocation, submission, event or drain failures; those Linux fault cases remain
unqualified on Windows. Disk persistence remains disabled. Physical memory
pressure, larger backing capacities, broader numerical quality and speed
qualification are separate work.

The unchanged Flash-Next continuation probe passes AR and MTP cross-slot
round-trips with the supplied `Qwen3.8-Flash-Next-UD-Q4_K_XL` four-shard model,
the shared Q8 MTP sidecar, and the automatically discovered BF16 projector.
Each run prefills two different 4,096-token histories, allows 4,224 positions
for the next decode, and commits 1 GiB of coherent backing. Capture uses four
64 MiB blocks: AR captures 131,614,880 private bytes and 103,825,408 row bytes;
MTP captures 133,032,096 private bytes and 112,473,856 row bytes.

Restoration into the other slot reproduces token history and logits bit for
bit; readback verifies every captured device component. The next decode step
also matches tokens, logits and draft/acceptance statistics. Nonzero MTP drafting
is asserted during that post-restore step. These are focused state-integrity
checks, not a broader model-quality or timing qualification. The probe's capacity
printout still uses raw HIP memory reporting; it does not qualify Windows
capacity limits under pressure.

Evidence is retained under `build/windows-gpu/pinned-20261012-200729`: native
CTest/build logs, AR/MTP probe output, exact commands, source base and binary
hashes, CMake toolchain configuration, and model file sizes/modification times.
Full model-file hashes were not collected. Formatting and documentation checks
pass. No production source change was needed, and the earlier inconclusive
performance qualification remains unchanged.

## Windows GPU queue policy

The server's automatic queue planning is Linux-only. Its KFD cross-process
census and measured text/audio caps do not establish a Windows policy: absent
`/sys` files are not evidence that the GPU has no other queues. A 14-line Windows
branch at the server's sole planning call leaves `GPU_MAX_HW_QUEUES` untouched.
An inherited setting remains the operator's responsibility; otherwise HIP uses
its runtime default. No Windows tuning option or duplicate planner is added.

At INFO level Windows startup reports, for example:

```text
event=queue_budget kind=llm observed=unknown budget=unknown expected_max=unknown cap=runtime census=unavailable
```

A nonempty inherited setting reports `cap=operator`. The line intentionally
does not predict resident queues, apply Linux's eight-queue budget, or issue
Linux's power/clock warning. Help, invalid invocations and quieter log thresholds
still suppress the startup diagnostic. Linux's queue implementation, measured
caps and tests are unchanged.

The new Windows-only `win32_queue_policy_test` exercises all five server
modalities with absent, empty, numeric and nonnumeric inherited values, all four
log thresholds, help and invalid addresses before model loading. It passes in
the bounded CPU preset, which now has **15 checks**, all passing in 17.22 seconds.
The unchanged Linux planner's synthetic KFD fixture test also passes when built
on Windows; this is not a Linux-hosted CI qualification.
The queue-policy test passes against the native HIP executable too, in 13.96
seconds. Formatting, documentation and dependency checks pass.

```powershell
ctest --preset windows-cpu
ctest --test-dir build/windows-gpu -R '^win32_queue_policy_test$' --output-on-failure
```

Selected Flash-Next AR/MTP live checks pass against the preceding WDDM binary
using the supplied four-shard Q4_K_XL model, shared Q8 MTP sidecar and BF16
projector, at 4,096 context tokens, one session and 2 GiB RAM cache. The unchanged
`content-preserve0-sampled0` functional case covers seven generation requests,
including two interrupted streams, RAM resume/replay and third-turn reuse.
Seeded output, token counts and expected prefill/cache work match exactly; AR
does not draft and MTP performs actual drafts. These checks also pass with an
explicit inherited `GPU_MAX_HW_QUEUES=2` on the new binary.

Per-request/phase timing comparisons retain the strict 5%/3 ms thresholds.
Both default-policy pairs per mode, unchanged-baseline controls and the explicit
operator-setting diagnostic use the same `gufo.exe` path and fresh processes.
AR cancellation-handoff queue wait spans 15.05–38.52 ms on unchanged baseline
controls and 27.93–38.26 ms on the default-policy candidate. The flagged MTP
snapshot spans 7.55–16.16 ms on baseline controls and 15.12–18.43 ms on the
candidate. Controls reproduce the stalls; observations overlap. No confirmed
timing regression is established, but both modes remain **inconclusive and
unqualified for performance**. The operator-setting diagnostic does not replace
qualification of the runtime default or establish a Windows tuning policy.

Evidence is retained under `build/windows-gpu/queues-20261012-202345`: build/CTest
logs, commands, complete server and request measurements, all comparisons,
source patch, binary hashes, CMake configuration and model size/mtime identity.
Full model-file hashes were not collected. Windows queue residency, idle power,
multiple GPU processes, broader model quality and other modalities' inference
throughput remain unqualified. Linux-hosted checks remain pending. This change
does not enable disk checkpoint persistence.

## Flash-Next broader runtime checks

The next qualification increment uses the same supplied four-shard Q4_K_XL
model, shared Q8 MTP sidecar, BF16 projector, TheRock 10.0.0 and production
executable. No engine, kernel or Linux test-harness change is needed.

All ten model-owned numerical operator checks pass on the 8060S in 95.05
seconds, with assertions active: MTP primitives, BLASLt, HC mixing, GDN,
attention, MoE epilogue/IDs, projection, routed WMMA and selection. Their
existing reference implementations and numerical envelopes are unchanged;
attention includes positions beyond 128K. These are operator contracts, not
a full-model F32 reference or quality-benchmark qualification.

The unchanged SDK suites `discovery`, `long-context`, `cache-depth` and
`stream-start` pass in both AR and MTP at 32,768 configured context tokens,
two execution slots and an explicit 8 GiB RAM snapshot budget. Each mode
records 36 HTTP requests, including five discovery probes and three deliberate
stream disconnects. The long-context history starts at 12,359 prompt tokens;
the deep histories reach 23,548. Checks cover JSON keyword recall, exact cached
replay, Chat/Responses switching, thinking limits/cancellation, concurrent
rewritten branches, side-conversation rotation, resume and exact uncached
controls. Stream headers arrive before cold prefill completes and at the
five-second bound while both slots remain occupied. Hidden private consoles
also verify graceful Ctrl+C shutdown after inference drains.

The 8 GiB budget produces real byte-capacity pressure. Both binaries log
refused snapshot copies; the deep-history unchanged retry prefills seven
assistant-opening tokens, as the existing test explicitly allows only with
matching refusal evidence. Expected reuse and uncached-output checks remain
strict. Disk caching is off; the disk-restarting `cache` suite
is excluded by the Windows contract, not counted as passed.

The full `cache-depth` suite also passes with one execution slot in each mode,
at the same 32K context and 8 GiB budget: another 16 requests per mode, including
the exact uncached controls. This tests RAM retention after the only execution
slot is reused. AR executes zero drafts. The two-slot MTP run records 610
proposed and 388 accepted draft tokens; the one-slot deep run records 48
proposed and 10 accepted. These counts establish execution, not speed.

Two-slot outputs, token counts and expected prefill/cache work match the
preceding Windows WDDM binary exactly. Per-request/phase comparisons retain
the strict 5%/3 ms limits. Focused repeats replay discovery, long context and
the first deep snapshot, with unchanged-baseline controls and the same executable
path. The AR first-deep snapshot spans 47.40–70.63 ms on baseline observations
and 60.11–61.68 ms on the candidate. No confirmed timing failure is established,
but variation and unconfirmed flags leave both modes **inconclusive and
unqualified for performance**. All original/focused observations are retained.
The one-slot run retains timings but has no matched speed qualification.

This increment qualifies selected Flash-Next behavior and numerical operator
contracts. Full-model reference/quality checks, the standard speed benchmark,
HIP failure injection, physical memory pressure and Linux-hosted checks remain
pending. Qwen27B Q4_K_XL and DFlash2 files were found locally but have not been
runtime-qualified here. The user confirmed that Qwen27B Q8_K_XL and DeepSeek
Flash 0731/DSpark weights are unavailable; those profiles remain unqualified.

The temporary Windows process wrapper invokes `openai_sdk.py` directly because
`run.py` owns POSIX signals. The original runner remains unchanged. Use UTF-8
mode for the Windows Python environment. SDK 2.41.1 matches
[the repository's pinned Nix package](https://github.com/NixOS/nixpkgs/blob/2fcb964de67fcf60b43471c55d5d99e61a9ccb5a/pkgs/development/python-modules/openai/default.nix);
HTTPX, JSON Schema and other package versions are retained in the evidence.
Initial environment/setup failures are retained and do not count as engine
qualification. No weights are downloaded and all API traffic stays on loopback.

Artifacts are retained under `build/windows-gpu/runtime-20261012-205456`,
including numerical output, wrapper/commands, SDK reports, complete request
measurements and server logs, package/toolchain identities, binary hashes and
model size/mtime identity. Full model-file hashes were not collected.
