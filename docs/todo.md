# Windows upstream-friction TODO

Goal: keep `windows-main` descended from official Gufo history while making
each `official/main` merge cheaper and less error-prone. Source analysis:
`git diff e060aeed...cdf793e7` (official head at last sync vs `windows-main`)
is 190 files, 48 under `src/` — a large share of which is the #699 revert
(§4), not Windows portability.

Hygiene items are done (see commit: `official` remote, skill checkout/remote
corrections, `tools/windows/local.json` defaults, `WINDOWS.md` CPU-CI counts,
`ci.yml` intent comment). What remains is below, roughly ordered by
leverage-per-effort. Check off with PR links as each lands.

## 1. Upstream portable fixes to shrink the 48-file `src/` delta (defer this for now)

Several Windows touches are pure-portable and could disappear from our diff
entirely if accepted upstream. Propose each as an isolated upstream PR when
authorized, then drop it from the maintained difference on the next sync.

- [ ] `src/core/json.hpp`: `size_t` vs `unsigned long long` constructor
  template. No behavior change on Linux; unblocks MSVC ABI.
- [ ] Aligned allocation: aligned `new` instead of `std::aligned_alloc`
  (absent from Windows CRT). Prefer standard portable code per
  [plan](plans/windows-compatibility.md#keep-the-maintained-difference-small).
- [ ] `src/models/deepseek_v4_flash/kernels/rocm/detail/ds4_rocm_runtime.hip.hpp`
  and `src/models/minimax_h3/media.cpp` one-liners — confirm portability,
  propose upstream.
- [ ] `tests/core/gguf_identity_test.cpp`: `std::filesystem::temp_directory_path()`
  instead of a hard-coded `/tmp` template. Same behavior on Linux.
- [ ] `src/core/platform/` (`device_memory.*`, `socket.hpp`,
  `cache_directory.hpp`): propose as a platform abstraction with Linux
  pass-through, so OS branches live in one place. Upstream's PR #711
  `net.{hpp,cpp}` leaf is already imported byte-identical and keeps the
  `SOCKET` width, but its call sites still store handles in `int` and it has no
  `errno` mapping or cancel-on-shutdown, so `socket.hpp` stays the
  implementation for now (see the
  [PR #711 sync entry](WINDOWS-UPSTREAM-SYNC.md#october-23-2026-pr-711)).
- [ ] Create `docs/WINDOWS-UPSTREAM-CANDIDATES.md` tracking file, owner,
  upstream issue/PR, and blocker for each candidate. The sync skill already
  says "propose that isolated fix upstream when authorized" but with no list,
  nothing ever leaves the diff.

## 2. Promote the validation harness out of ignored `build/`

The cold-prompt request body is already reproducible from
`WINDOWS-UPSTREAM-SYNC.md`; what lives only in ignored `build/` evidence dirs
is the server orchestration and the per-phase comparison.

- [x] `tools/windows/first-prompt-control.py`: the versioned cold-prompt
  generator (the `random.Random(813)` body in `WINDOWS-UPSTREAM-SYNC.md`) plus
  fresh-process server orchestration for AR/MTP, reuse-on then reuse-off. This
  check caught both the n-gram ~50% regression and #699; it must not live only
  in `build/` dirs that won't exist next quarter.
- [x] `tools/windows/compare-phases.py`: per-request/phase comparison with
  the repo's 5% and 3 ms gates, no averaging, unchanged-binary controls,
  automatic retention of binary SHA + colocated DLL set + `/props` +
  timings. Today's flow depends on tribal `build/sync-*/` evidence.
- [x] `tools/windows/local.json` follow-up: `local.example.json` already has a
  `Models` key but nothing reads it (`build.ps1` ignores it). Make the
  harnesses above consume it so model-shard locations stop living in prose.
- [x] Idle-wake stall: the first GPU submission after about 5 s of device idle
  stalls 0.3–0.9 s in the Windows driver. It lands inside slot reassignment,
  so a fresh arm's first request hit it at random and flagged queue/wall/TTFT.
  `compare-phases.py` now reports the per-request `slot_wait_ms` without
  gating on it and subtracts it from the phases that contain it (see the
  [sync procedure](WINDOWS-UPSTREAM-SYNC.md#reproduce-the-first-request-control)).
- [ ] (Deferred) Engine fix for the same stall: it also costs real users about
  0.4 s of TTFT on any request after ≥5 s idle, in AR and MTP. Candidates
  include touching the GPU (e.g. starting the slot reset) when a request
  arrives, overlapping it with HTTP parsing and tokenization, or keeping the
  device awake while a server is loaded. Each edits shared engine/server files
  (`src/cache/slot.cpp`, the Flash-Next `ContinuationAdapter::Invalidate` →
  `Session::Reset` path), so propose it upstream (§1) rather than carry it.
  First check whether Linux/amdgpu shows the same stall and whether a
  Windows/AMD power setting avoids it. Repro: one server, requests after 0, 5,
  15, 30 and 60 s idle; compare `residual_wait_ms` deltas.

## 3. Automate the manual sync procedure (~600 lines of copy-paste today)

- [x] `tools/windows/known-regressions.json`: machine-readable mirror of the
  sync log's known-regressions table (PR, merge SHA, revert SHA, affected
  paths, reintroduction checks). Markdown stays human-readable; JSON is the
  gate.
- [x] `tools/windows/sync-inventory.ps1 OFFICIAL_HEAD WINDOWS_BASE`: emit the
  PR table (number/title/URL/merge SHA via `gh`), `diff --stat` both
  directions, and a fresh sync-log entry skeleton with
  `validated / reviewed-unchanged / pending (reason)` slots per contract.
  Driven by `known-regressions.json`, it also fails if
  `WINDOWS_BASE..OFFICIAL_HEAD` intersects a recorded regression and reports
  whether upstream touched each regression's paths (e.g. #699: `engine.cpp`
  vision/catch-up/lookup paths, `sampling.cpp` compact distributions,
  `executor.cpp` verification workspace), so a landed fix is noticed without
  rediscovery. Do not reapply without citing the sync log entry and passing
  the cold-start control. One tool, not a separate watcher script.
- [x] Batch planning in the same inventory: classify each incoming commit
  (convergence/timing/contained/inert, plus a shared-edit flag) with
  `tools/windows/sync-batching.json` and suggest cut points at release tags
  or class limits, with each batch's required checks and timing suspects
  ([batching](WINDOWS-UPSTREAM-SYNC.md#batching)).
- [x] `tools/windows/diff-guard.ps1`: diff `official/main..HEAD`, fail if a
  shared `src/`/`tests/` file outside an allowlist changed or a `// WINDOWS:`
  marker is missing. Keeps the "small difference" contract enforced, not
  aspirational. (Single guard; §7's diff-lint is this tool. Markers are
  enforced per file with `"markers": true` in `shared-edits.json`; §7 turns
  them on.)
- [x] Hosted gates for sync candidates: both workflows run only on push to
  `main`/`windows-main` or on PRs targeting them, so pushing a
  `sync/official-*` branch alone triggers nothing (`ci.yml` has no
  `workflow_dispatch`). Replace the "use an available Linux/Nix environment"
  hand-wave with: open a draft PR against `windows-main`, then `gh run watch`
  the Linux + Windows-CPU runs.

## 4. Resolve the #699 revert upstream

The #699 revert, not Windows portability, is a large share of the `src/`
delta (~600 lines across `engine.cpp`, `executor.*`, `kernels.hip.cpp`,
`batch.cpp`, `sampling.*`, `mtp_sampling.hpp`, …). It also deletes upstream
tests (`sampling_test`, `verification_sampling_test`, `prompt_lookup_test`,
`session_test`) and replaces upstream's "Exact sampled decode" doc sections.
Every upstream follow-up to #699 will conflict here.

- [x] When authorized, report the Windows/TheRock first-request MTP decode
  regression upstream with the cold-prompt repro (§2) and the sync log's
  measurements. Reported as
  [gufo-org/gufo#745](https://github.com/gufo-org/gufo/issues/745); official
  #733 does not fix it.
- [ ] Once a fix lands upstream, drop the revert on the next sync (gated by
  `known-regressions.json`, §3).

## 5. De-conflict repeat-offender docs

- [x] Model docs (`EXPERIMENTS.md`/`QUALITY.md`/`BENCHMARKS.md`): the Oct-21
  sync conflicted because both branches insert at the top, and the #699
  revert removed upstream sections. Move Windows evidence into sidecars
  (e.g. `docs/models/<model>/WINDOWS.md`) and leave the upstream files
  untouched. Append-at-bottom still conflicts with revert deletions; do not
  use a `union` merge driver (it silently duplicates table rows and
  re-adds reverted content).
- [x] Single source of truth: the remote table/procedure is duplicated in the
  sync skill and plan §Future official updates (and summarized in
  `WINDOWS.md`'s intro). Make `WINDOWS-COMPATIBILITY.md` canonical; the skill
  and plan link to it instead of duplicating remote tables, paths, and check
  counts. Dated check counts in `WINDOWS.md` evidence entries are history,
  not drift — leave them.

## 6. Keep upstream lines in `CMakeLists.txt` byte-identical

Replacing `if (WIN32) … else() … endif()` with a call into a
`cmake/Windows.cmake` function still edits upstream lines, so nearby
upstream refactors still conflict. Instead, override from outside:
`Windows.cmake` already uses `cmake_language(DEFER CALL …)`, so no "late
include" hook is needed in the root file.

Current root sites: platform check (line 3), `include(cmake/Windows.cmake)`,
WebP selection, `gufo-server` copy-vs-symlink target, ROCTX optional, install
`RENAME gufo-server.exe`, fault libraries, `cache_disk_faults_test`,
`cmake/Checks.cmake`. Also `tests/cache/CMakeLists.txt` (boundary test args).

- [x] Fault libraries, `cache_disk_faults_test`, `Checks.cmake`: upstream
  lines restored. `gufo_windows_overrides` in `Windows.cmake` sets
  `EXCLUDE_FROM_ALL` on `cache_disk_faults` (`device_loss_faults` already is)
  and `DISABLED` on `cache_disk_faults_test`. `Checks.cmake` configures on
  Windows; `check-pr` is never built there.
- [x] WebP: the upstream `pkg_check_modules` line stands unchanged. vcpkg's
  host `pkgconf` (in `vcpkg.json`) is on the toolchain's program path, so
  `PKG_CONFIG_EXECUTABLE` needs no override, and `libwebp.pc` resolves.
- [x] Install rename: the upstream `install(CODE … create_symlink)` line is
  restored. Its failure is ignored, and `Windows.cmake` installs the
  `gufo-server.exe` copy.
- [ ] ROCTX optional and `gufo-server` copy-vs-symlink: better as upstream
  candidates (§1) than relocated; until then they stay as small edits.
- [x] `tests/cache/CMakeLists.txt`: retain the upstream command behind a
  marked Windows dispatch to the adapter in §7. A small shared hook remains;
  the upstream script has no configuration or platform hook.
- [ ] Verify with `git diff --stat`: realistic floor is the platform check,
  the include hook, and whatever upstream has not yet accepted.

## 7. Stop editing shared build/CI/test files

- [ ] `CMakePresets.json` (low priority): the `"include"` field needs preset
  schema version 4 (CMake 3.23); the file is version 3 with a 3.21 minimum,
  so moving presets out requires a shared version bump. Our additions are
  appended to each array and conflict only when upstream also appends.
- [x] `tests/cache/boundary_test.py` is byte-identical to the last imported
  official version. The Windows-only adapter
  `tests/platform/win32_cache_boundary_test.py` checks the shim's real link
  metadata against `win32_cache_dependencies.json`, then runs the unchanged
  upstream script with only the reviewed shim and CMake scope markers removed.
  Other cache dependencies remain visible to upstream's checks. A marked
  dispatch in `tests/cache/CMakeLists.txt` selects the adapter on Windows;
  the Linux command is unchanged. `tools/ci/check-docs.py` and
  `tools/ci/check-dependencies.py` already match upstream.
- [x] Shared tests: prefer the existing pattern — new `win32_*` files, shared
  files untouched. Triage of the current edits:
  - `sampling_test`, `session_test`, `verification_sampling_test`,
    `prompt_lookup_test`: #699 revert, not Windows edits — handled by §4, no
    markers.
  - `gguf_identity_test` (`temp_directory_path` instead of `/tmp`): portable;
    tracked in the §1 upstream-candidate list.
  - `http_server_test`, `audio_websocket_test`, `run.py`, `test_runner.py`:
    carry `// WINDOWS:` (or `# WINDOWS:`) markers in every changed hunk,
    enforced by `"markers": true` in `shared-edits.json` and
    `diff-guard.ps1` (§3). Their executable code is unchanged by this cleanup.

## 8. Small-carveout APU support (follow-up to PR #91)

- [ ] Set the PAL workarounds automatically for small BIOS carveouts. With a
  0.5 GB carveout, the reporter of
  [PR #91](https://github.com/thomas9120/gufo-windows/pull/91) needed
  `GPU_MAX_SUBALLOC_SIZE=0` to keep small allocations out of the ~335 MiB
  local heap. They also saw 16 upload streams exhaust it; `GPU_MAX_HW_QUEUES`
  (already honoured on Windows, see `src/cli/serve/serve.cpp`) may avoid
  serializing `weight_upload.cpp`. Both must be set before the HIP runtime
  initializes, so detect the carveout in the launcher (DXGI
  `DedicatedVideoMemory`) and set them only for small carveouts. Do not set
  them for 64–96 GB carveouts, and do not edit upstream `main.cpp`. First
  confirm on the reporter's hardware that the DXGI admission fix plus these
  variables load and serve Flash-Next. Add PR #91's other Windows-wide
  changes (hipBLASLt, hipGraph, component cache, snapshot pool) only if
  that test proves them necessary, and gate them on the carveout.
