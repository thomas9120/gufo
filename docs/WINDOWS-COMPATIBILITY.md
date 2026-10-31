# Windows compatibility contracts

Use this checklist for every merge from `official/main` into `windows-main`.
Review changed implementations and new callers even when Git merges cleanly.
Record the upstream/candidate SHAs, checks run and any unqualified cases in the
sync review. Build commands and qualification limits live in
[Windows status](WINDOWS.md); Linux behavior and checks must remain intact.
Record imported PRs, revision identities and outcomes in the
[upstream sync log](WINDOWS-UPSTREAM-SYNC.md), following its repeatable procedure.

- [ ] **Cached concurrent n-gram reads.** Flash-Next on Windows reopens the
  bound GGUF descriptor with `O_CONCURRENT_RANDOM`: cached, overlapped random
  reads, without `FILE_FLAG_NO_BUFFERING`. Preserve descriptor identity and
  concurrent offset reads; direct reads can serialize on NTFS while the shard
  is mapped. Implementation: [`NgramTable::Open`](../src/models/qwen38_flash_next/ngram.cpp)
  and the flag/reopen/transfer adapters in
  [`posix.cpp`](../compat/win32/posix.cpp).
  Regression: [`qwen38_flash_next.ngram`](../tests/models/qwen38_flash_next/ngram_test.cpp)
  checks row decoding, offsets, descriptor identity and counters. It does not
  check throughput: also run the
  [first-request control](WINDOWS-UPSTREAM-SYNC.md#reproduce-the-first-request-control)
  against the previous Windows binary (AR and MTP when their paths change). A
  fresh process does not flush the filesystem cache. A warmed
  pp2048 benchmark alone missed this regression; see the
  [measured control](models/qwen3.8-flash-next/WINDOWS.md#cold-prompt-control-october-20-2026).

- [ ] **WDDM admission budgets.** Admission uses the active integrated HIP
  adapter's LUID/node and refreshed DXGI local plus nonlocal budgets, clamping
  each segment's remaining headroom to zero. Failed/unsupported queries retain
  the complete HIP result, including its status and null-output behavior.
  Implementation: [`DeviceMemoryInfo`](../src/core/platform/device_memory.cpp)
  and [`QueryVideoMemoryBudget`](../src/core/platform/device_memory_win32.hpp).
  Audit new `hipMemGetInfo` callers so admission uses this helper; informational
  raw-HIP queries are intentional exceptions.
  Regression: [`win32_device_memory_test`](../tests/platform/win32_device_memory_test.cpp)
  covers an independent live DXGI oracle, allocation/free, another thread,
  exhausted budgets, partial/failing queries, overflow and null outputs.
  Requires Windows HIP hardware; actual multi-GPU switching remains unqualified.

  Host snapshot budgets separately use
  [`AvailableMemoryBytes`](../src/core/platform/os_info.cpp), which reports
  native available physical RAM on Windows. Preserve the Windows boundary
  that skips Linux CMA/cgroup refinements and the existing host reserve.
  [`win32_host_test`](../tests/platform/win32_host_test.cpp) checks page size
  against `GetSystemInfo`, available RAM against surrounding native queries,
  and the snapshot budget/ceiling derived from those values. This does not
  replace WDDM device-admission checks.

- [ ] **Pinned memory and transfer lifetime.** Backing/staging allocations stay
  coherent, accounted and alive while pinned or used by asynchronous transfers.
  Drain transfers before releasing buffers or reusing stream leases; preserve
  rollback and row padding. Implementation:
  [`committed_backing.cpp`](../src/core/hip/committed_backing.cpp),
  [`staging.cpp`](../src/core/hip/staging.cpp),
  [`transfer_pool.cpp`](../src/core/hip/transfer_pool.cpp) and
  [`snapshot_transfer.hpp`](../src/core/hip/snapshot_transfer.hpp).
  Regression: [`win32_pinned_transfer_test`](../tests/platform/win32_pinned_transfer_test.cpp)
  checks registered backing mappings, coherent staging flags, accounting,
  ownership, concurrency, bound execution-stream lifetime and real H2D/D2H copies.
  The upstream `qwen_dflash_upload_lifetime_test` also checks delayed upload
  failure, source lifetime and recovery through a Windows-only
  [HIP import hook](../tests/platform/win32_dflash_upload_fault.cpp).
  [PR #688 pinned capture](WINDOWS-UPSTREAM-SYNC.md#pr-688-windows-dflash2-continuation-latency)
  remains deferred; keep its independent upload-failure draining fix.
  For snapshot changes, also run the AR/MTP cross-slot round-trip
  [continuation probe](WINDOWS.md#windows-pinned-backing-and-transfers).
  Requires Windows HIP hardware; broader HIP fault injection and physical memory
  pressure remain unqualified.

- [ ] **Sockets and shutdown.** Preserve native-width Winsock handles, errno
  mapping, millisecond timeouts, nonblocking listeners and blocking workers.
  Local shutdown must cancel blocked I/O and join workers; disconnect handling
  and orderly close must preserve final HTTP/WebSocket data.
  Implementation: [`socket.hpp`](../src/core/platform/socket.hpp),
  [`http_server.cpp`](../src/cli/serve/http_server.cpp),
  [`shutdown_signal.cpp`](../src/core/platform/shutdown_signal.cpp) and
  [`websocket.cpp`](../src/cli/serve/websocket.cpp).
  Upstream's [`net.hpp`](../src/core/platform/net.hpp) leaf (official PR #711)
  is imported byte-identical but unreferenced: its call sites store handles in
  `int` and it has no `errno` mapping or cancel-on-shutdown, so keep
  `socket.hpp` as the implementation until the
  [convergence slice](WINDOWS-UPSTREAM-SYNC.md#october-23-2026-pr-711) lands.
  The shutdown handler is upstream's
  [`shutdown_signal`](../src/core/platform/shutdown_signal.hpp) leaf
  (official PR #713): it owns both the POSIX `sigaction` pair and the Windows
  console handler, which holds close/logoff/shutdown events for a bounded
  drain. Do not reintroduce a second console handler in `http_server.cpp`.
  Regression: [`http_server_test`](../tests/cli/http_server_test.cpp),
  [`audio_websocket_test`](../tests/cli/audio_websocket_test.cpp) and
  [`win32_server_shutdown_test`](../tests/platform/win32_server_shutdown_test.py).
  The latter sends real Ctrl+C/Ctrl+Break events during idle, active and partial
  requests; forced termination is cleanup, not a pass. Covered by Windows CPU CI.

- [ ] **Filesystem identity, privacy and failures.** Preserve handle-relative
  operations after directory renames, atomic no-replace publication, reparse
  rejection, token-user private ACLs, large offsets, Unicode paths and honest
  flush errors. Implementation: [`filesystem.cpp`](../compat/win32/filesystem.cpp),
  [`posix.cpp`](../compat/win32/posix.cpp) and
  [`directory.cpp`](../compat/win32/directory.cpp).
  Regression: [`win32_filesystem_test`](../tests/platform/win32_filesystem_test.cpp),
  [`win32_compat_test`](../tests/platform/win32_compat_test.cpp),
  [`gguf_identity_test`](../tests/core/gguf_identity_test.cpp) and the trace
  cases in `http_server_test`, all in Windows CPU CI. The component store in
  [`disk.cpp`](../src/cache/disk.cpp) uses the explicit
  [Windows rebuildable-cache contract](WINDOWS.md#windows-component-disk-cache),
  covered by [`win32_disk_store_test`](../tests/platform/win32_disk_store_test.cpp).
  Keep the older [`continuation_disk_store.cpp`](../src/cli/serve/continuation_disk_store.cpp)
  guarded. Process-death tests do not prove power-loss namespace persistence.

- [ ] **GPU queue policy.** Windows leaves `GPU_MAX_HW_QUEUES` untouched,
  preserving the operator setting or HIP runtime default. Missing Linux KFD
  sysfs means an unavailable census, not zero competing queues; startup reports
  unknown observed/budget/expected counts. Keep Linux's measured planner on Linux.
  Implementation: the OS boundary in [`serve.cpp`](../src/cli/serve/serve.cpp).
  Regression: [`win32_queue_policy_test`](../tests/platform/win32_queue_policy_test.py)
  covers all five modalities, inherited values, log thresholds, help and invalid
  invocations before model loading. Covered by Windows CPU CI; repeat against
  the HIP executable when server startup changes. This is not a Windows queue
  residency or performance qualification.

Run `ctest --preset windows-cpu --no-tests=error` after the bounded CPU build;
the [Windows workflow](../.github/workflows/windows-cpu.yml) runs that gate.
Build affected GPU/model test targets explicitly, then select the named tests
with `ctest --test-dir build/windows-gpu -R '^TEST_NAME$' --output-on-failure --no-tests=error`.
GPU/model checks and the long-prompt control are local gates, outside hosted
CPU CI. Use [functional checks](../tests/functional/README.md) and the existing
per-request timing limits for affected runtime paths; retain failures and
unchanged-binary controls when timings are noisy. Update this checklist's links
and coverage whenever an upstream change moves or replaces an implementation.

## Repository roles

Expected remotes and branches, subject to explicit user changes:

| Remote/ref | Purpose |
| --- | --- |
| `official` → `https://github.com/gufo-org/gufo.git` | Official source of updates; merge `official/main`. |
| `origin` → `https://github.com/thomas9120/gufo-windows.git` | The Windows fork; publish Windows work here when requested. |
| `upstream` → `https://github.com/pixmaate/gufo.git` | A different fork; not the official update source. |
| `windows-main` tracks `origin/windows-main` | Keep this tracking relationship; do not change it to `official/main`. |

`windows-main` stays descended from official history. Syncs are ordinary
merges of a recorded `official/main` SHA, and sync PRs use merge commits so
ancestry is kept. Never squash, rebase or force-push the maintained branch.
Host-specific paths (ROCm, vcpkg, models) belong in ignored
`tools/windows/local.json` (see
[`local.example.json`](../tools/windows/local.example.json)), never in tracked
files.

## Maintained difference

Keep the difference from official Gufo small and checked by tools:

- Windows-only files (`compat/win32/`, `win32_*` tests, `tools/windows/`,
  `WINDOWS*.md`) are fork-owned additions; the guard accepts them.
- Every edited upstream file is listed with a reason in
  [`shared-edits.json`](../tools/windows/shared-edits.json).
  [`diff-guard.ps1`](../tools/windows/diff-guard.ps1) fails on unlisted edits;
  CI runs it.
- Windows model evidence goes in `docs/models/<model>/WINDOWS.md` sidecars,
  for example [Flash-Next](models/qwen3.8-flash-next/WINDOWS.md). Leave the
  upstream `BENCHMARKS.md`, `QUALITY.md` and `EXPERIMENTS.md` identical to
  official, even for a reverted PR. The sidecar lists the upstream sections
  that do not apply.
- Reverted upstream PRs are recorded in
  [`known-regressions.json`](../tools/windows/known-regressions.json) and the
  [sync log](WINDOWS-UPSTREAM-SYNC.md#known-upstream-regressions).
  [`sync-inventory.ps1`](../tools/windows/sync-inventory.ps1) gates on them.
