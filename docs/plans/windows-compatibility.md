# Minimal native Windows integration

Status: stage one and the transport/host increments of stage two implemented;
persistence foundations qualified, initial checkpoint-store port deferred
on `feat/windows-cpu-compat`. The native Windows CPU CLI builds; the bounded
preset includes host, HTTP, audio WebSocket, and console-shutdown checks. See
[Windows status](../WINDOWS.md) for commands, provenance, validation, and
remaining limitations. Windows CPU CI is implemented and all 15 hosted checks
pass after the bounded-test fixture correction. Stage three is
in progress: native HIP, WDDM admission, pinned-memory
checks and selected Flash-Next AR/MTP checks pass. Stage four remains pending;
the optional browser launcher is integrated as a separate tool. The later
[component-cache implementation](../WINDOWS.md#windows-component-disk-cache)
uses an explicit rebuildable-cache contract on local NTFS; the older store
remains disabled. Full GPU/model qualification
remains pending.

## Objective and baseline

Build and run the current official Gufo engine natively on Windows 11 x64,
on AMD Strix Halo (`gfx1151`), while keeping future official updates easy to
merge. Windows compatibility is the priority; the GUI is an optional separate
launcher.

Inspected on 2026-10-12:

- Official source: `gufo-org/gufo` at
  `8d4e1a2b74c94752b9b16b1dda153cbf52638443`, this worktree's HEAD.
- Fork reference: `thomas9120/gufo-adapted`, `windows-port` at
  `ab4d98189a6d8103fce29d2537e4113da3da2420`.
- Both SHAs match their remote branch heads at inspection time.
- Common ancestor: `d9a84f13f35d1f98da22886a12eb25dc7062e392`.
  Git reports 155 official-side and 187 fork-side commits after that ancestor.
  Some official fixes were adapted into the fork, so these are ancestry counts,
  not counts of missing features.

The complete tip-to-tip diff spans 575 files. Much of that difference is
official development, including the new common cache package. It is not the
size of the required Windows port. The initial Windows compatibility commit,
`edb2f8b0629005f2852d4543a3c24786b56979a5`, touched 52 files and added roughly
3,300 lines, predominantly in a separate compatibility directory.

**Recommendation:** implement Windows support on top of this official baseline.
Use the fork as a source for specific adaptations rather than merging its
complete branch or replacing official source files with fork versions.

## Keep the maintained difference small

Use these boundaries:

- `compat/win32/`: Windows implementations of the POSIX operations Gufo uses.
  Reuse the existing shadow headers, `posix.cpp`, and `spawn.cpp` at the pinned
  fork revision. Extend only operations required by the current official tree.
- `cmake/Windows.cmake`: collect Windows build wiring in one module, included
  from the root CMake file only on Windows. Keep unavoidable early compiler
  probe configuration before `enable_language(HIP)`.
- `tools/windows/`: a prerequisite check, build script, and pinned Windows
  dependency manifest. These prepare the environment and invoke CMake; CMake
  continues to own targets, flags, dependencies, and installation.
- `src/core/platform/`: retain the fork's small socket and device-memory
  helpers where POSIX emulation cannot preserve the required behavior.
  Keep CPU compatibility separate from HIP/DXGI dependencies.
- Existing engine files: change specific calls or add short Windows branches
  where necessary. Preserve their current upstream implementations.

Avoid a new generic operating-system framework, a duplicate Windows engine,
whole-model refactors, or a generated patch applicator. Initially reuse the
fork's compatibility surface intact rather than spending time rewriting or
aggressively pruning it. Keep its include paths, definitions, and libraries
scoped to Gufo-owned Windows targets wherever practical.

Preserve Linux/Nix settings, official release/version handling, model framing,
cache layouts, and public CLI/API behavior. Prefer standard portable code for
an isolated issue such as aligned allocation when it avoids extra platform
branches without changing the algorithm.

## Reuse, adapt, and defer

Reuse the latest fork versions of the following, with their source SHA recorded
in the implementation change:

- POSIX compatibility files and the HIP `<cmath>` workaround.
- Socket helpers: Winsock errors, timeout units, socket closure, listener
  shutdown, and WebSocket cancellation.
- WDDM/DXGI device-memory reporting, matched to the active HIP adapter.
- Windows diagnostics, memory reporting, cache-directory selection, and
  process-spawning adaptations.
- `tools/windows/build.ps1`, simplified to build this engine and stage its
  required runtime DLLs and kernel libraries.
- The pinned vcpkg dependencies. Keep Linux's existing dependency discovery;
  WebP uses the same `PkgConfig::WEBP` path through vcpkg's host `pkgconf`.

Useful provenance starts with the original compatibility commit above,
`9bc346fa50a945232f2e41bc6bfca7ff4b1477f2` (build scripts),
`0e58ece75648bd56965c1fd77fbdf9d4915fde4a` (vcpkg manifest), and
`8f826b1e92d7e5e96544f1ce1b33a1ecade8e168` (Windows diagnostics fix).
Use the current fork files, not just the original commits, to retain subsequent
fixes. Apply source hunks against current official code deliberately.

Defer disk checkpoint persistence, guided installers, updater, fork release
workflow, custom upstream-sync tools,
`GUFO_PLATFORM_TUNING`, and fork-only
MTP/sampling options. Windows performance optimizations can be evaluated later
only if the official implementation exposes a measured problem. They are not
a prerequisite for the initial compatibility port.

## Gaps that copying the old port will not solve

### Current disk cache

[`src/cache/disk.cpp`](../../src/cache/disk.cpp) is new relative to the fork.
It uses `mkdirat`, `fdopendir`/`readdir`, and
`syscall(SYS_renameat2, ..., RENAME_NOREPLACE)` in addition to file locks,
descriptor-relative operations, and file/directory synchronization.

The fork has no directory-enumeration shim or `mkdirat` implementation, and its
generic `syscall` returns `ENOSYS`. Its `renameat` implementation replaces an
existing destination, which does not satisfy this cache's no-replace operation.
Its `fsync` accepts some directory/read-only flush failures as success; that
cannot establish the new cache's publication and reclamation durability.

Keep the cache algorithm and on-disk format. Extend the shim for ordinary
missing POSIX operations. For Linux-specific publication, use one narrow
operation with Linux and Windows implementations if that is clearer than
emulating a general syscall. Preserve atomic no-replace behavior, stable
directory-handle identity, exclusive ownership, reparse-point rejection, and
crash recovery. Identify and test the Windows durability contract explicitly;
do not claim directory durability on the strength of a successful no-op.

The existing shim also synthesizes POSIX ownership/mode fields and makes
`chmod`/`fchmod` no-ops. Review the older identity and continuation-cache checks
that depend on those fields. Where they enforce privacy, Windows needs an
equivalent access-control check or a documented, explicit limitation.

The initial integration deferred checkpoint persistence. The subsequent
[component-cache implementation](../WINDOWS.md#windows-component-disk-cache)
retains Linux durability and selects an explicit Windows rebuildable-cache
contract, with native store recovery/privacy checks. The older continuation
store remains guarded. RAM continuation reuse, GGUF digest caching and private
tracing are independent of disk checkpoints.

The cache is compiled into the engine even when runtime disk caching is off.
Turning disk caching off does not remove this build dependency.

### New GPU/cache paths

[`executor.cpp`](../../src/models/qwen38_flash_next/kernels/rocm/executor.cpp)
checks device headroom when admitting snapshot backing. This call site was not
covered by the old port's device-memory replacements. The GPU-budget increment
routes all six current production admission sites through `DeviceMemoryInfo`,
retaining Linux's direct HIP pass-through. Audit new `hipMemGetInfo` sites when
merging future upstream updates. The loader's informational query stays raw HIP.

Focused native checks now exercise the current
[`committed_backing.cpp`](../../src/core/hip/committed_backing.cpp),
[`staging.cpp`](../../src/core/hip/staging.cpp), and snapshot transfers on
TheRock. Coherent backing/staging, accounting and lifetime checks, real transfers
and Flash-Next cross-slot restoration pass without production-code changes.
The Linux HIP fault-injection harness remains unqualified on Windows; larger
capacity/pressure checks are also pending. See the
[pinned-memory record](../WINDOWS.md#windows-pinned-backing-and-transfers).
The fork's older cache does not qualify these newer contracts.

The official server also automatically plans GPU queues from Linux KFD sysfs.
On Windows, missing sysfs is not evidence that no other process has queues.
Keep that measured Linux policy on Linux; preserve explicit operator settings
on Windows and use the runtime default until Windows measurements justify a
policy. Report unavailable Linux diagnostics honestly. This boundary is now
implemented at the server's sole queue-planning call: Windows leaves
`GPU_MAX_HW_QUEUES` untouched and logs unknown census/budget/expected counts.
The Linux planner and its measured caps remain unchanged. See the
[queue-policy record](../WINDOWS.md#windows-gpu-queue-policy).

### Tests and build targets

[`tests/cache/CMakeLists.txt`](../../tests/cache/CMakeLists.txt) uses ELF linker
`--wrap`, and some cache tests use `fork` and `/proc/self/fd`. Functional fault
libraries use `dlsym`/`LD_PRELOAD`. These need platform-specific wiring, not just
new headers.

Keep the Linux test paths. For Windows, use subprocess-based crash/death checks
and focused test-only failure injection around the compatibility operations.
Do not add a fake `fork` implementation or count omitted fault cases as passes.
Maintain an explicit list of Linux-only harnesses and their Windows coverage.

[`tests/cache/boundary_test.py`](../../tests/cache/boundary_test.py) currently
allows only `Threads::Threads` as a cache link dependency. If the CPU Windows
shim is linked there, update that reviewed dependency rule narrowly and verify
its transitive dependencies. Do not admit the HIP/DXGI helper or broad engine
targets into the common cache.

## Implementation sequence

Each increment should have its own Conventional Commit and validation record.
Begin implementation on a new branch descended from the pinned official HEAD;
keep the existing `windows-port` branch available throughout qualification.

1. **Windows build and CPU compatibility.** Add the compatibility directory,
   Windows CMake module, dependency manifest, and minimal build/check scripts.
   Allow Windows x64 while retaining `gfx1151` as the production GPU target.
   Retain the official version/revision definitions in the script. Handle DLL
   placement and the `gufo-server.exe` copy without requiring Windows symlinks.
   Adapt cache filesystem operations needed for the CPU CLI to link. Keep the
   existing presets usable; add Windows overrides only where necessary.
   Verify configuration, CPU build, `--version`, `--help`, GGUF/parser checks,
   and focused compatibility tests.

2. **Server and cache semantics.** Adapt sockets, signals/shutdown, diagnostics,
   aligned allocation, and host-memory reporting against the official sources.
   Qualify private filesystem operations and Windows test harnesses. Keep the
   Linux suite intact; add a separate bounded Windows CPU CI job. Verify HTTP,
   streaming/disconnects, WebSockets, cancellation, shutdown, file locking,
   large offsets, Unicode/spaced paths, operation-level no-replace publication,
   and filesystem failures. Checkpoint-store recovery is deferred. Update the
   cache dependency boundary check with the reviewed CPU shim.

   Deliver this stage in separate commits:

   - **Transport and shutdown (implemented):** native socket handles and I/O,
     nonblocking accept with blocking workers, disconnect/cancellation,
     WebSocket idle/close semantics, and actual console-event subprocess tests.
     The later persistence foundations qualify private content tracing.
   - **Host integration (implemented):** native CPU topology and OS diagnostics,
     host-memory reporting/admission, and Unicode Windows cache-directory
     selection. Unqueried GPU/driver/memory-type fields remain unavailable.
     Aligned allocation was completed in stage one.
   - **Persistence foundations (implemented):** ACLs, stable directory identity,
     and native subprocess/failure-injection tests. Retain the Windows guards
     until each store's guarantees are demonstrated. The dependency boundary
     and isolated locking/offset/no-replace operations were covered in stage one.
     The foundation increment qualifies protected ACLs, handle-relative file
     operations, native operation-level death/failure checks, private tracing,
     and GGUF identity caching. Both checkpoint stores remain guarded. Native
     directory flush succeeds with write access, but this process cannot flush
     `C:\Users` or the volume root required by the new store's ancestor walk.
     Both stores are deferred to keep the initial port small. Any later enabling
     change must resolve durability and qualify store-level recovery; a weaker
     power-loss guarantee has not been selected. See the validation record.
   - **Windows CPU CI (implemented):** a separate workflow automates the
     qualified bounded suite with pinned standalone LLVM and the manifest's
     vcpkg baseline, preserving the existing Linux checks. Local validation
     precedes hosted qualification. Hosted compilation and all 15 checks pass;
     the large-offset compatibility fixture is now sparse to avoid allocating
     and flushing 4 GiB during the bounded suite. Its timeout correction passes
     locally and in the hosted correction run.

3. **Native HIP runtime.** Enable the production Windows build with the fork's
   pinned TheRock 10.0.0 as the initial reference toolchain. Verify its
   compatibility with the current official kernels rather than assuming it.
   Stage runtime libraries, adapt WDDM memory admission, and check pinned
   backing and transfers. First exercise Flash-Next AR/MTP and Qwen27B
   AR/DFlash2 with actual local models, images, RAM reuse, long-context
   continuation, and cancellation. Disk restart is excluded from this initial
   Windows scope. Then qualify the other supported model paths with focused
   model-owned checks. A milestone for one model is not a claim that all model
   families are qualified.

   The native HIP build and initial Flash-Next AR/MTP smoke check are implemented.
   Buffered/streamed generation, one RAM continuation restore in each mode, actual
   MTP drafts, and one AR image request pass on the local 8060S. WDDM admission is
   implemented with native budget/adapter/fallback checks. Selected Flash-Next
   AR/MTP cancellation and RAM replay checks match the earlier binary; timing
   qualification remains inconclusive. Focused pinned-memory/transfer checks and
   4,096-token Flash-Next AR/MTP cross-slot state-integrity checks pass. Windows
   HIP fault injection and physical memory pressure, other model paths,
   full-model numerical quality and speed qualification remain pending. Selected
   32K-context Flash-Next AR/MTP long-context, deep RAM reuse and streaming-header
   checks pass with two slots; deep reuse also passes with one slot. All ten
   model-owned numerical operator checks pass. Timing qualification remains
   inconclusive. See the
   [broader runtime record](../WINDOWS.md#flash-next-broader-runtime-checks) and
   [the validation record](../WINDOWS.md#initial-native-hip-live-inference).
   The [GPU-budget record](../WINDOWS.md#windows-gpu-budget-admission) details
   the adapter selection, scope, native checks, and retained timing controls.
   The [pinned-memory record](../WINDOWS.md#windows-pinned-backing-and-transfers)
   identifies the native allocation, ownership and copy checks and their limits.
   The Windows queue-policy boundary is implemented; all five server modalities
   preserve inherited queue settings or the runtime default, without applying
   the Linux KFD-based planner.

4. **Qualification and maintenance handoff.** Run the official Linux hosted
   checks and formatting checks, Windows CPU checks, affected numerical-quality
   tests, and the standard speed benchmark. Use
   [`tests/functional/`](../../tests/functional/README.md) for selected live
   suites; shared compatibility behavior calls for all four text profiles,
   including `long-context` and RAM continuation/cache scenarios, without running
   unrelated full model sweeps or video generation. Replay `pi_agent.py` if an
   affected coding-agent workflow is reported. Retain every result and
   toolchain/model/cache identity.
   Observe the repository's strict per-request timing rules; a missing model
   skip or inconclusive timing is not a qualification pass. Document the
   supported Windows configuration and any remaining limitations in
   `docs/WINDOWS.md`, and make narrowly scoped platform-documentation updates.
   The existing `cache` suite also tests disk restart; record those Windows
   cases as excluded by scope rather than passed. Keep Linux disk checks intact.

Stages 1-3 are incremental development milestones. The port is complete only
when the intended runtime paths and RAM cache guarantees are covered, Linux
checks pass, and documented support claims match actual evidence.

The existing build script copies an OpenMP runtime from Visual Studio's
`debug_nonredist` directory for developer use. Do not turn that into a public
binary release. Source builds are the initial deliverable; redistributable
packaging is a separate follow-up if requested.

## Future official updates

Keep this integration branch descended from official history. Update it through
ordinary merges from `official/main` (see the canonical
[repository roles](../WINDOWS-COMPATIBILITY.md#repository-roles); `upstream` is a
different fork). Retain complete official ancestry. Apply the
[Windows acceptance policy](../WINDOWS-UPSTREAM-SYNC.md#windows-acceptance-policy)
to skip or explicitly revert PRs that introduce Windows regressions, and
document their evidence and reintroduction requirements. Use an isolated
candidate branch for each update, run the bounded Windows/Linux gates, then
merge the verified candidate into the maintained branch. Do not routinely
rebase a shared branch or rewrite its published history.

Use the [Windows compatibility contracts](../WINDOWS-COMPATIBILITY.md) as the
review checklist for each sync. They identify the maintained OS boundaries,
their regression checks, and the local GPU/model gates beyond hosted CPU CI.
Append imported PRs and the validation record to the
[upstream sync log](../WINDOWS-UPSTREAM-SYNC.md); its procedure records exact
merge identities and distinguishes import from platform qualification. Read its
known regressions before accepting a sync, and preserve explicit compatibility
reverts until their reintroduction requirements pass. In particular, #699 is
deferred for a Windows first-request MTP decode regression; its presence in
upstream ancestry does not mean its code should be reapplied.

Keep the [maintained difference](../WINDOWS-COMPATIBILITY.md#maintained-difference)
small; `diff-guard.ps1` and the sync inventory make it visible at each update. Resolve conflicts locally at the OS
boundary. If a fix is portable and useful upstream, propose that isolated fix
upstream when authorized so it can eventually disappear from the maintained
difference.

The GUI remains an independent launcher of `gufo serve`, using the engine's CLI
and HTTP endpoints. It is separate from the engine and requires no kernel or
cache changes. Its command builder has been reconciled with the official CLI;
older Windows-fork-only options are ignored when settings are loaded.
