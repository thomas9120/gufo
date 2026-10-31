---
name: sync-windows-upstream
description: Merge gufo-org updates from official/main into this fork's windows-main branch, preserving Windows compatibility and upstream ancestry through focused review and validation. Use for upstream syncs, conflict resolution during those syncs, and sync readiness reviews.
---

# Sync official Gufo into Windows

Maintain `windows-main` as the Windows integration branch descended from
official Gufo history. Read the repository's `AGENTS.md`, the
[maintenance plan](../../../docs/plans/windows-compatibility.md#future-official-updates)
and [Windows compatibility contracts](../../../docs/WINDOWS-COMPATIBILITY.md)
before starting. The checklist is the canonical implementation/test map; update
it when files move or contracts change rather than copying it into this skill.

## Establish the checkout and remote roles

The canonical checkout is `C:\P2027\gufo-windows` on branch `windows-main`.
Always discover the actual root with `git rev-parse --show-toplevel`; use that
root for commands and logs instead of hardcoding the path.
Inspect `git worktree list` before switching branches
or creating another checkout. Preserve unrelated worktrees and their metadata.
A stale, git-detached copy exists at `C:\P2027\windows-main` (its `.git` file
points at a deleted `C:/P2027/gufo/.git` worktree, and its file set has
diverged from `windows-main`); do not use it as a checkout, and do not remove
it as part of a sync until its owner confirms it holds no unique work.

Verify `git remote -v`, the current branch, tracking configuration and worktree
status against the canonical
[repository roles](../../../docs/WINDOWS-COMPATIBILITY.md#repository-roles).
Verify `official` points at the official URL there before fetching. If it is
absent, add it with `git remote add official https://github.com/gufo-org/gufo.git`.
If it exists at a different URL, investigate before changing it.
Do not repoint `upstream` or change the user's other remote configuration.
Prefer `jj` if available and usable for this checkout, otherwise Git; the
examples below use Git. Check `gh auth status` before GitHub operations.

## Prepare and merge a candidate

1. Inspect local changes and ahead/behind state. Preserve local commits and
   unrelated edits; do not reset, force checkout, automatically stash or silently
   commit them. If the current tree has unrelated edits, use a separate candidate
   worktree from the intended committed base. Resolve any essential base choice
   from the session before asking the user.
2. Fetch `official` and `origin`. Record the local Windows base SHA and fetched
   `official/main` SHA. Compare `windows-main` with `origin/windows-main` before
   deciding the integration base; do not pull blindly or discard unpublished
   Windows commits. If official is already an ancestor of the chosen Windows
   base, report it up to date rather than making an empty merge.
3. Inventory the incoming commits and the maintained Windows difference:
   `./tools/windows/sync-inventory.ps1 -WindowsBase $windowsBase
   -OfficialHead $officialHead -OutFile build/sync-YYYY-MM-DD/inventory.md`.
   It resolves every incoming PR, flags known Windows regressions
   ([`known-regressions.json`](../../../tools/windows/known-regressions.json))
   arriving with the sync or touched by upstream, lists files changed on both
   sides, suggests batches and emits the sync-log entry skeleton. Exit code 1
   means a known regression must be reverted on the candidate.
   Use CodeGraph first for code exploration when `.codegraph/` exists, per
   repository instructions. Include new callers of OS-sensitive operations,
   not just files with merge conflicts.
4. Choose the batches following
   [batching](../../../docs/WINDOWS-UPSTREAM-SYNC.md#batching): start from the
   inventory's **Suggested batches** (cut at release tags, at most two
   convergence and four timing commits per batch) and record any cut you move
   and why. Release notes are not an inventory; use the commit range.
5. Create a unique `sync/official-YYYY-MM-DD` candidate from the chosen Windows
   base and merge each batch's recorded official SHA in order, one merge
   commit per checkpoint. Run that batch's required checks before merging the
   next. Do not routinely rebase the shared branch or cherry-pick only
   selected official fixes.

Example from a clean, confirmed `windows-main` base; run commands sequentially
and inspect exit status before proceeding, especially in Windows PowerShell
where native command failures do not automatically stop a command list:

```powershell
git fetch official
git fetch origin
git switch windows-main
$windowsBase = git rev-parse HEAD
$officialHead = git rev-parse official/main
$syncBranch = 'sync/official-' + (Get-Date -Format 'yyyy-MM-dd-HHmmss')
git switch -c $syncBranch
# For each batch, in order, using its merge target from the inventory:
$batchEnd = 'BATCH_END_SHA'
git merge --no-ff $batchEnd -m "chore(sync): merge official through $($batchEnd.Substring(0, 8))"
```

Resolve conflicts at the OS boundary, retaining the current upstream algorithm
and Linux behavior alongside the narrow Windows adaptation. Do not use whole-
file ours/theirs resolutions without reviewing the discarded changes. Preserve
CMake-owned flags/dependencies, Linux/Nix configuration, official versioning,
public CLI/API behavior and model/cache formats. Keep the GUI an independent
launcher. Do not reintroduce old fork-only tuning switches or enable deferred
Windows disk checkpoint stores merely to make a merge build.

## Review and validate

Check off every [compatibility contract](../../../docs/WINDOWS-COMPATIBILITY.md)
(the inventory's skeleton lists them). Record each as unchanged/reviewed,
validated, or pending with its reason; a clean merge is not validation.
Each batch lists the checks its classes require. A batch without timing
commits needs no timing comparison. When a timing gate fails, revert-test
the batch's timing suspects first; when the CPU gate fails, bisect the
batch's first-parent commits.

- Build and run the bounded Windows CPU gate using the documented toolchain:
  `./tools/windows/build.ps1 -Preset windows-cpu -Vcpkg PATH`, followed by
  `ctest --preset windows-cpu --no-tests=error`.
- Build the candidate Windows HIP executable and affected GPU/model test targets
  when inference or shared runtime paths change. Follow
  [Windows status](../../../docs/WINDOWS.md) for commands and current limits.
  Run the named WDDM, pinned-transfer and n-gram checks when their contracts are
  affected; snapshot changes also need the AR/MTP continuation probe.
- Use [functional checks](../../../tests/functional/README.md) for affected
  models/modes and histories. Shared text behavior calls for all four profiles;
  avoid unrelated full model sweeps. Retain numerical quality checks and the
  standard speed benchmark required by repository guidance.
- For prefill/n-gram/loader/I/O changes, compare the previous Windows binary
  and candidate with a varied 10–16K-token first HTTP prompt in fresh server
  processes and repeat with prompt reuse disabled. Include AR/MTP as affected.
  Warmed pp2048 alone previously missed a roughly 50% first-prompt regression
  caused by losing cached overlapped n-gram reads. Run
  `tools/windows/first-prompt-control.py` as the
  [sync procedure](../../../docs/WINDOWS-UPSTREAM-SYNC.md#reproduce-the-first-request-control)
  describes. It retains identities, responses and per-phase verdicts. Compare
  with the checklist's
  [control record](../../../docs/models/qwen3.8-flash-next/WINDOWS.md#cold-prompt-control-october-20-2026).
- Keep model, toolchain, launch settings, cache history and power conditions
  matched. Capture binary/revision identities, commands, individual request
  timings, output and actual cache/draft work. Apply repository timing limits
  per request/phase, investigate failures with alternating/unchanged controls,
  and retain failed/noisy observations. Do not average away or relabel a
  regression as a pass. Keep baseline binaries with their required runtime DLLs;
  do not overwrite an executable used by a live GUI/server. Stop only test
  processes owned by the run.
- Rerun the inventory with `-Candidate HEAD`; it fails if reverted code is
  present. Run `./tools/windows/diff-guard.ps1` and keep the
  [maintained difference](../../../docs/WINDOWS-COMPATIBILITY.md#maintained-difference)
  rules: a new shared-file edit must be deliberate and listed, and Windows
  model evidence goes in the model's `WINDOWS.md` sidecar.
- Run `python tools/ci/check-docs.py`, `git diff --check` and required formatting
  for changed C++. Run the bounded Linux checks through hosted CI: pushing the
  candidate branch alone triggers nothing, so open a draft PR against
  `windows-main` (when publication is authorized) and `gh run watch` the CI
  and Windows CPU runs, or use an available Linux/Nix environment. Windows results do not qualify Linux, and missing
  hardware/models or skipped tests remain pending, not passed. Fix confirmed
  regressions before publishing a qualified sync.

Host-specific paths live in ignored `tools/windows/local.json` (see
`tools/windows/local.example.json`). `tools/windows/build.ps1` uses it for
any `-Rocm`/`-Vcpkg`/`-Ninja` option left at its default.
`first-prompt-control.py` reads its `Models` directory. If `local.json` is
missing, seed it from the previously observed values: TheRock 10.0.0 at
`C:\TheRock\build`, vcpkg at
`C:\Users\pegas\Documents\Projects-2026\Strix-halo-optimizations\vcpkg`
(the build helper default `C:\vcpkg` was absent on that host), and Flash-Next
model shards plus the shared-Q8 MTP sidecar under
`C:\Users\pegas\Documents\Llama\LLama-GUI\models\Qwenflash-next-4kxl`.
Verify paths and versions before reuse; never bake host paths into tracked
scripts. Ignored `build/` investigation scripts
and old binaries may be missing in another checkout; use maintained test tools
or retain a reproducible workload with the new sync evidence.

## Integrate and hand back

Follow the user's requested endpoint: review only, local integration, or
publication. Creating/using this skill is not itself a request to perform a
sync, push branches, open a PR or merge on GitHub. Existing task authorization
continues to apply; do not ask again for actions already requested.

When local integration is requested and the Windows base is still unchanged,
fast-forward `windows-main` to the validated candidate. If it has advanced,
integrate the intervening changes on the candidate and rerun affected checks
before updating it. Preserve official ancestry. For an authorized GitHub sync
PR, target `windows-main` in the user's fork and use a merge commit, not squash
or rebase merging. This Windows maintenance policy differs from official
`main`'s usual squash release workflow. If repository settings prevent merge
commits, report the blocker rather than silently losing ancestry. Never force-
push the maintained branch. Use a Conventional Commit title and register the
PR with the current thread when the host provides PR-linking tools.

Report both base SHAs and final candidate SHA, conflicts/resolutions, the
per-contract outcomes, exact checks/results, pending qualifications and any PR URL.
Verify the recorded official SHA is an ancestor of the final candidate with
`git merge-base --is-ancestor`. Leave an unqualified candidate clearly marked
as such. Do not create releases or manually bump versions/changelogs for a sync.
