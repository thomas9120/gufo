# Windows upstream sync log

Track merges from [official Gufo](https://github.com/gufo-org/gufo) into the
Windows integration branch. This log starts after the October 2026 forward-port;
it is not a retroactive inventory of the old fork's selective imports.
An imported PR is not automatically qualified on Windows.

## Windows acceptance policy

This is a Windows-specific Gufo port. Preserve Windows compatibility,
correctness, stability and performance when accepting upstream changes.
Upstream inclusion or passing Linux checks does not override a Windows
regression.

- Check the known-regression entries before every sync. Skip or defer the
  code from PRs with confirmed Windows regressions until a fix passes the
  affected Windows checks. A focused compatibility fix may be retained with
  the PR when it is validated and documented.
- Preserve official ancestry: normally merge the recorded upstream head,
  then explicitly revert the regressing PR on the candidate. Record it as
  **reverted/deferred**, rather than imported and validated. If dependencies
  prevent a safe isolated revert, defer the dependent changes or the candidate
  until the compatible combination is validated.
- Confirm attribution against the previous Windows base with matched inputs
  and toolchain. Keep inherited failures, missing coverage and noisy results
  visibly pending; they are not automatically evidence that an incoming PR
  caused a regression.
- Record every skipped, reverted or deferred PR in the sync entry and known
  regressions section. Include its URL and merge SHA, affected Windows behavior,
  reproduction/toolchain details, baseline and candidate evidence, disposition
  and revert/fix SHA, affected dependencies, and required reintroduction checks.
  Keep failed observations and the original entry when a later fix resolves it.
- Preserve these exclusions during future conflict resolution, backports and
  related upstream changes. Reapply a deferred PR only after reviewing its fix
  and passing the recorded Windows checks against the previous Windows base.
  Append the fixing SHA, validation evidence and new status to its record.

## Known upstream regressions

[`known-regressions.json`](../tools/windows/known-regressions.json) mirrors
these entries for the sync tools: PR, merge/revert SHAs, identifiers that must
stay absent while reverted, and reintroduction checks. Update both together.

### PR #688: Windows DFlash2 continuation latency

**Bounded pinned prompt capture is deferred on Windows.** Official
[#688](https://github.com/gufo-org/gufo/pull/688),
`b0eb5d476d07b659fb0d6a448b56f66d5420a113`, is an ancestor through
merge `225ec080`; explicit revert `432163e9` removes the optimization.
Commit `77a58de7` separately retains only its upload-failure cleanup and
unchanged upstream lifetime fixture. Successful injections keep the existing
stream wait; failed injections now drain outstanding readers before returning.

Two candidate runs (`792150d6` binary SHA-256 prefix) and three unchanged
baseline runs (`b2df4482`) use the same executable path, all 143 runtime files,
Qwen 27B Q4_K_XL/official Q4_K_M DFlash2/projector, 32K context, two sessions
and effective 4 GiB RAM caches with equal staging/disk capacities. In the
first `long-context` suite, before the later divergent cancellation histories,
all outputs, prompt/cache work and sampled replay drafts match: 12,454 prompt
tokens reused in full, seven completions, 11 proposed/five accepted drafts.

| Matched sampled replay phase | Baseline range (ms) | Pinned-capture candidate range (ms) |
| --- | ---: | ---: |
| Client wall | 351.75-358.76 | 405.42-419.80 |
| Cache restore | 15.27-16.61 | 20.77-21.44 |
| Server TTFT | 19.40-21.70 | 26.30-26.70 |

The unchanged upstream timing qualification finds **nine failed, 73 passed and
42 inconclusive cells** for this entire first suite at the existing 5% and
3 ms limits. The scoped evidence copies every first-suite request byte for
byte, verifies settings/budgets and retains source hashes; it makes no claim
about later histories. The full comparisons and their failures remain intact.
No inference workaround or timing-margin change is retained. Attribution is
to the tested #688 combination; the complete runtime cause is not established.

The full DFlash2 comparison also fails on an image continuation after different
cancellation frontiers (273 versus 278 cached tokens) change seeded output.
Both builds replay exactly within themselves. Explicit matched-frontier image
probes produce identical output/work across builds and reproduce both original
output hashes on baseline, so this is not evidence of new transfer corruption.
An unchanged baseline also reproduces the legacy-tool seven-token re-prefill
variation. Neither observation is relabelled as a full comparison pass.

A delayed-copy probe confirms Windows pageable D2H copies already block while
pinned copies return asynchronously. Omitting the upstream waits would therefore
be speculative; no such patch was made. Physical-memory pressure, other HIP
failures and a full performance qualification remain open.

Evidence ([evidence archive](#evidence-archive)): `sync-688-2026-10-23/`,
especially `long-context-qualification.json`, `qualify-long-context.py`, original/repeat
functional reports, `fixed-image-frontier/` and `copy-semantics.log`.
Reintroduction must preserve upload draining, pass affected numerical and
cancel/image/cache/batch checks, verify shared-cache Flash-Next AR/MTP behavior,
and clear matched per-request timing gates with unchanged-base controls.
Also run varied 10-16K-token first requests with reuse on/off and pp2048/tg128.
The revert remains effective in future merges until deliberately qualified.

### PR #699: Windows first-request MTP decode regression

**Avoid reapplying #699 unchanged on Windows.** Its code is reverted by
`161035d8`; upstream ancestry is retained by merge `54fb4b4e`. PRs #692,
#540 and #690 remain included. This is a Windows/TheRock observation, not
an assertion about Linux performance.

With the same model, toolchain, runtime DLLs, server path and 11,036-token
fresh-process request, pre-sync first MTP decode measures 57.51, 53.86 and
51.32 ms in separate controls. The full import measures 60.90 and 63.35 ms;
removing #699 alone measures 53.55 ms. The rebuilt explicit revert measures
53.25/51.52 ms on first/repeat decode, with identical output and cache/draft
work. Its 6,557.75/6,284.98 ms prefill also remains within the baseline gate.
The focused import/base pair exceeds the unchanged 5% and 3 ms request-phase gate. Warm repeats are about 51-53 ms;
outputs and prompt/cache/draft counts agree. See the model's
[individual observations](models/qwen3.8-flash-next/WINDOWS.md#sync-first-decode-control-october-21-2026).

Temporary host-stage traces locate roughly 7-9 ms in the first neural
predictor's Q8 MoE enqueue after KV-only prefill. The baseline pays this
first-use cost during prefill instead. This suggests lazy HIP setup moving
into decode; it does not establish a complete root cause. Removing eager
vision setup does not fix it (59.60 ms). Restoring full scalar predictor
catch-up measures 52.75 ms once, but the combined scalar/batch fallback
measures 66.46 ms. Explicit startup function preparation also fails (67.02 ms).
None of those experimental changes is retained. Profiling measurements are
diagnostic and are not qualification timings.

Reported upstream as [gufo-org/gufo#745](https://github.com/gufo-org/gufo/issues/745).
Official #733 (lone greedy MTP requests use the small draft head) does not
fix it. On the October 23 Windows tree plus #733, ABBA fresh-process controls
measure first decode at 62.47, 61.35 and 64.56 ms with #699 versus 52.93, 51.45
and 53.58 ms without it; repeat decode, prefill, output and cache/draft counts
are unchanged. #733 alone is neutral. Evidence
([evidence archive](#evidence-archive)): `exp-733-2026-10-23/`. #733 itself is
not imported yet.

**Reintroduction requirement:** review the upstream fix, then run
[the first-request control](#reproduce-the-first-request-control) against the
previous Windows binary. Retain every
phase, output and cache/draft count; a warmed benchmark alone is insufficient.
A later merge will not automatically undo the revert because #699 is already
an ancestor. Any deliberate reapplication must cite this entry and pass the
focused cold-start control plus affected correctness checks.

## Evidence archive

Sync evidence is written to ignored `build/sync-*` directories in the task
worktree. Before that worktree is removed, its text artifacts (JSON, JSONL,
logs, scripts, Markdown, diffs) are copied to the maintainer's evidence
archive under the same directory name; on the reference host that is
`C:\P2027\gufo-evidence\`. Evidence references in this log name those
archived directories. Binaries, model files and caches are not archived.

## Batching

Import official history in batches rather than one PR at a time. A batch must
end at an official commit so that the merge keeps official ancestry. It is
therefore a contiguous run of incoming commits; selecting non-adjacent PRs
would mean cherry-picking. Only the cut points are chosen.

- **Cut at release tags by default.** A `vX.Y.Z` tag passed upstream's
  complete Devlab functional suite, and merging its release commit keeps
  `version.txt` and `CHANGELOG.md` in step with official. Take the inventory
  from the commit range, not the release notes: notes omit `build`, `ci`,
  `test` and `chore` PRs and have missed late-merged `feat`/`perf` PRs
  (v0.22.0 omits #705; v0.23.0 omits #752).
- **Classify every incoming commit by what it requires**, using the path rules
  in [`sync-batching.json`](../tools/windows/sync-batching.json):

  | Class | Meaning | Required work |
  | --- | --- | --- |
  | convergence | Windows portability areas: `compat/`, `src/core/platform/`, `src/core/hip/`, `src/cache/`, Windows workflows | Choose the fork or upstream implementation for each overlap, review the affected contracts, run the Windows CPU gate and HIP build |
  | timing | Hot paths of models with Windows timing evidence, shared decoding code, and source reverted for a known regression | Matched Windows timing controls and the first-request control |
  | contained | Other source and tests | Windows CPU gate and affected functional suites |
  | inert | Documentation, Nix, CI, functional suites, release commits | Documentation, formatting and build checks |
  | shared (flag) | Touches a source or test file listed in `shared-edits.json` | Review the fork's edit and its contract, even after a clean merge |

- **End a batch early** when the next commit would exceed two convergence or
  four timing commits. Keep related convergence work, for example one
  platform leaf and its adoption, in one batch rather than mixing several
  unrelated fork-or-upstream decisions into one merge. **Continue past a
  release** whose batch has no convergence or timing commit.
- **Merge each batch end as its own checkpoint** on a single candidate branch,
  then run that batch's checks before merging the next. One sync PR and one
  log entry cover all checkpoints; record each checkpoint's official SHA and
  merge commit in the entry's checkpoint table.
- **Narrow failures by class.** When a batch fails a timing gate, revert-test
  only its timing commits, listed as timing suspects; when the CPU gate fails,
  bisect the batch's first-parent commits. Then apply the acceptance policy to
  the responsible PR.

The inventory applies these rules under **Suggested batches** and lists each
batch's merge target, per-commit classes, required checks and timing suspects.
The suggestion is advisory: move a cut point when review shows a dependency
or a lower-risk boundary, and record the reason in the sync entry.

## Repeatable procedure

1. Follow the [sync skill](../.agents/skills/sync-windows-upstream/SKILL.md).
   Verify [repository roles](WINDOWS-COMPATIBILITY.md#repository-roles),
   worktree status and local versus remote `windows-main` before fetching. Preserve unpublished Windows work.
2. Record the Windows base and fetched `official/main` SHA before merging.
   Run `tools/windows/sync-inventory.ps1 -WindowsBase WINDOWS_BASE
   -OfficialHead OFFICIAL_HEAD -OutFile build/sync-YYYY-MM-DD/inventory.md`.
   It lists **all** incoming commits, resolves PR titles and merge SHAs with
   `gh`, lists release commits separately, reports files changed on both sides
   and upstream work on reverted regions, suggests [batches](#batching) and
   emits an entry skeleton. Exit code 1 means the sync imports a known
   regression.
3. Apply the Windows acceptance policy and known-regression entries above.
   Choose the batches. On an isolated candidate descended from the Windows
   base, merge each batch's exact official SHA in order. An already isolated
   T3 task branch is a suitable candidate. Preserve official ancestry through
   a merge commit per checkpoint. Review cleanly merged Windows call sites as
   well as conflicts; retain both platforms' evidence.
4. Review every [compatibility contract](WINDOWS-COMPATIBILITY.md) at each
   checkpoint. Audit new callers and moved implementations. Run each batch's
   required checks before merging the next one, then the bounded Windows CPU
   gate, documentation/formatting checks and the available Linux gate on the
   final candidate. Preserve individual timing results and failures.
   Revert/defer confirmed Windows regressions and validate the resulting
   combination before accepting the sync. Rerun the inventory with
   `-Candidate HEAD` (it fails if reverted code is present), run
   `tools/windows/diff-guard.ps1` (see the
   [maintained difference](WINDOWS-COMPATIBILITY.md#maintained-difference)),
   and open a draft PR against `windows-main`:
   pushing a `sync/official-*` branch alone triggers no hosted checks. Watch
   the Linux and Windows CPU runs with `gh run watch`.
5. Append an entry below with the PR table, base/head identities, resolutions,
   per-contract outcomes, exact checks, evidence location and pending limits.
   Put model measurements in the model's `WINDOWS.md` sidecar, not in the
   upstream model documents.
   List skipped/reverted/deferred PRs and their reintroduction requirements
   explicitly; do not silently omit them from the inventory. Record new
   reverts in `known-regressions.json`.
   Verify each PR merge SHA and the recorded official head with
   `git merge-base --is-ancestor SHA HEAD`. Do not replace old entries.
6. Integrate a qualified candidate into `windows-main` only after rechecking
   its base. Publication follows the requested endpoint and the
   [merge policy](WINDOWS-COMPATIBILITY.md#repository-roles).

For the next sync, copy the shape of the latest entry and replace its evidence.
For a batched sync, keep the skeleton's checkpoint table and give each
checkpoint its own merge review and validation subsections.
Use **validated**, **reviewed/unchanged**, or **pending (reason)** per contract;
do not count missing models, excluded disk persistence or noisy timings as passes.

For Windows functional timing comparisons, use the budget preflight wrapper:

```powershell
python tools/windows/compare-functional.py --pair BASE_RUN CANDIDATE_RUN --output NEW_COMPARISON.json
```

It delegates to the upstream functional comparator with the same per-request
gates and accepts its repeated `--pair` and `--control` arguments. Before
comparing timings, it reads both server startup logs in every run and rejects
clamped explicit RAM requests or different effective RAM, staging or disk
capacities. Identical launch arguments alone do not establish matched memory
budgets. Keep rejected runs as evidence; do not use them to clear earlier
matched failures.

### Reproduce the first-request control

Finish builds first and stop nothing you do not own. Run
[`first-prompt-control.py`](../tools/windows/first-prompt-control.py):

```powershell
python tools/windows/first-prompt-control.py --base-binary PREVIOUS\gufo.exe `
  --head-binary CANDIDATE\gufo.exe --repeats 2 --output build/sync-DATE/first-prompt
```

For each mode (AR with `--speculative off`, MTP with the shared-Q8 sidecar),
it alternates base/head in ABBA order. Each arm stages the executable, its DLLs
and `hipblaslt/` at the same path, then starts a fresh private server with
`--context 32768 --sessions 2 --think off --cache-ram-bytes 8589934592`. It
POSTs the retained 11,000-word body below to `/v1/chat/completions`, first
with `cache_prompt: true` and then with `cache_prompt: false`, and stops the
server with a console break. Models default to `Models` in
`tools/windows/local.json`. Omit `--head-binary` for an unchanged-binary
control.

The output directory must be new. It keeps `control.json` with settings,
binary/DLL/model identities, commands, `/props`, complete responses and
wall/phase timings. It also keeps one server log per arm and
`comparison.json`. [`compare-phases.py`](../tools/windows/compare-phases.py)
reproduces the comparison from `control.json`. Correctness problems fail the
run: wrong prompt reuse, a wrong answer, an HTTP error or an unclean stop.
Each phase is compared on its own with the repository's 5% and 3 ms rule; it
counts only when every repeat moves the same way, and it is compared only when
both arms did the same prompt/completion/draft work. Exit status 0 means
passed, 1 failed and 2 inconclusive. An unchanged-binary control with any
moved phase is inconclusive and measures noise. Investigate flags with more
repeats or a focused control, and save failed observations as well as
successes. For these artifacts, expect 11,036 prompt tokens, zero reused
tokens and `ACK`.

`cache_snapshot_ms` and `cache_restore_ms` time a pageable device-to-host copy,
so their duration follows the payload rather than the request. On this host the
same binary moved by up to 53% between repeats at a byte-identical payload (the
unchanged-binary control of October 24, 2026, kept in the
`sync-noise-floor-2026-10-24` [evidence archive](#evidence-archive): 82.96 ms
against 54.27 ms for the same 1.07 GB), which is wider than the 5%/3 ms rule,
so the fixed rule cannot judge them. The
comparison therefore requires the payload bytes to match as part of the work
and reports a move inside `MEMCPY_REPEATABILITY` (55%, the measured envelope) as
`within noise` together with the payload and the implied throughput, in the
phase cell and in a note. That recording does not qualify the phase: it says
the instrument cannot resolve it. A move beyond the envelope, a changed
payload, or evidence without the byte count keeps the strict rule. Prefill,
TTFT, wall and decode are never excused this way — they are what the control
exists to catch, and their measured repeatability (decode reached 7.4% on the
same binary) is a reason to add a repeat pair, not to widen the gate.

On this host, the first GPU submission after the device idles for about 5 s
stalls for 0.3–0.9 s in the driver. This happens in AR and MTP, with any
binary, and also mid-process after an idle gap. A fresh arm's first request
hits it at random (7 of 16 short MTP arms, October 22, 2026), inside slot
reassignment. A settle delay makes it certain rather than removing it, and a
warm-up request would defeat the control. The comparison therefore derives
each request's `slot_wait_ms` from the server's cumulative
`component_cache.global_spill.residual_wait_ms`, subtracts it from the wall,
queue and TTFT phases that contain it, and reports `slot_wait_ms` without
gating on it. A slot wait that is slower in every repeat gets a note: check the
server logs before calling it noise. Evidence that lacks the field is compared
unadjusted.

The retained request body, for reference:

```python
import random

words = ("river town family valley stone bridge boats timber salt wool market "
         "wheat children forest quiet garden road lake tree green water blue").split()
passage = " ".join(random.Random(813).choices(words, k=11000))
body = {
    "model": "gufo",
    "messages": [
        {"role": "system", "content": "Read the archive. Follow the final user instruction exactly."},
        {"role": "user", "content": passage + "
Reply with exactly the word ACK."},
    ],
    "max_tokens": 128, "temperature": 0, "seed": 42,
    "chat_template_kwargs": {"enable_thinking": False},
}
```

## October 24, 2026: PR #722, #707 and #729

Status: **imported and locally qualified on `6665f4edda22`; draft PR #88,
hosted gates passed on `f9093207`**. Three checkpoints end before official
#705, which conflicts in `engine.cpp` and `prompt_lookup.hpp` and sits next to
the [#688](#pr-688-windows-dflash2-continuation-latency) and
[#699](#pr-699-windows-first-request-mtp-decode-regression) regions. It is
deferred until upstream's fix for those is available. Two Windows toolchain
problems in #729 are repaired by a retained, marked compatibility edit.

- Windows base: `0e1783d6947a27ad5767df885b6ff6be292401ee` (PR #86 merged).
- Previous official ancestor: `79c2dcc56f00c69d4085e52bde6d290b74a99ccd`
  (official #713).
- Imported official head: `ddc31dc7685101b1d2336328a293b72fab0bed70`.
- Scope: #722, #707 and #729 only. #705 and later commits, including the
  0.22.0 release commit `7b1bf049`, are outside this layer.
- Evidence ([evidence archive](#evidence-archive)): `sync-722-707-729/`, still
  under the task worktree's `build/` until archived.

| PR | Upstream change | Merge SHA | Checkpoint |
| --- | --- | --- | --- |
| [#722](https://github.com/gufo-org/gufo/pull/722) | fix(serve): accept standard image detail values as automatic detail | `9fa36451facdf2b231d52afec72670a0fe2543b5` | `67b8ef06` |
| [#707](https://github.com/gufo-org/gufo/pull/707) | fix(qwen38-flash-next): give each HIP stream its own qfn_mmq scratch arena | `68ff41a86f1e76bfd61ca85e47722ae78c17f05e` | `bbd3a3d0` |
| [#729](https://github.com/gufo-org/gufo/pull/729) | feat(platform): add the publish and prefault leaves | `ddc31dc7685101b1d2336328a293b72fab0bed70` | `e4e9d432` |

All three merge without conflicts. Compatibility fix commits: `6665f4ed` and
the comment-only marker commit `9f6555fc`.

### Merge review

#722 and #707 merge cleanly and touch no Windows-owned code. #707 keeps one
scratch arena per `(device, stream)` instead of one per context; its
`qfn_mmq_release_stream` call is in `Executor::~Executor`. The #699 revert is
untouched and its recorded identifiers stay absent.

#729 replaces the POSIX-only plan-database publication in
`hipblaslt_plan_database.cpp` and the `madvise`-based body of
`mapped_prefetch.hpp` with the `publish` and `prefault` leaves, which already
carry Win32 paths (`MoveFileExA`, `PrefetchVirtualMemory`, SEH page touching).
It merges cleanly, but two defects only show up in Windows builds:

1. **HIP build.** `.hip` translation units reach `prefault.hpp` through
   `mapped_prefetch.hpp` (`minimax_h3/prompt_encoder.hip`). clang's gfx1151
   device pass rejects SEH (`error: SEH '__try' is not supported on this
   target`), so the candidate did not build. Upstream's Windows CI builds CPU
   and cross-builds only. The helper is host-only; it is compiled out under
   `__HIP_DEVICE_COMPILE__`.
2. **Fault reporting.** `platform_prefault_test` segfaulted. TheRock clang 23
   keeps no SEH scope around a `__try` that holds only loads: the object has
   no exception handler and the filter never runs (`-fasync-exceptions` or a
   call inside the scope fixes it; MSVC `cl` is unaffected). The page touch now
   goes through a volatile function pointer so clang keeps the scope, rather
   than changing codegen for the whole build with `-fasync-exceptions`. The
   test passes in the CPU and GPU presets.

Both edits are in `src/core/platform/prefault.hpp`, carry `WINDOWS:` markers and
are listed in `shared-edits.json`. They are upstream candidates.

### Compatibility and validation

| Contract | Outcome |
| --- | --- |
| Cached concurrent n-gram reads | Reviewed/unchanged: no n-gram or loader change; `ngram_cache_hits` and `ngram_disk_reads` match across the base and head arms. |
| WDDM admission budgets | Validated for the measured workload: the GPU Process Memory counters (dedicated, shared, local, committed) are byte-identical for base and head at idle and after two prompts, AR and MTP, two ABBA pairs each (`gpu-memory/`). #707's per-stream arenas add no measurable footprint with `--sessions 2` and one request at a time; concurrent sessions were not exercised. |
| Pinned memory and transfer lifetime | Reviewed/unchanged; #688 pinned capture stays deferred and its identifiers are absent. |
| Sockets and shutdown | Validated: all 16 live arms stopped gracefully with exit code 0, and the CPU gate runs the shutdown and Winsock tests. |
| Filesystem identity, privacy and failures | Validated for the new leaves: `platform_publish_test`, `platform_prefault_test` and `hipblaslt_plan_cache_test` pass in both presets, and the repaired fault path reports `ERROR_NOACCESS`. Not exercised live: the Windows plan-database publication and a prefault of real weights (see below). |
| GPU queue policy | Reviewed/unchanged: no queue-policy code; the CPU startup-policy test passes. |

Completed checks:

- Native Windows CPU configure/build and **16/16 CTests pass**. The three new
  tests are outside the preset's filter, so they were built and run explicitly
  and pass (`platform_publish_test`, `platform_prefault_test`,
  `hipblaslt_plan_cache_test`).
- Native HIP `gufo` at `6665f4edda22`, SHA-256
  `4e2ab445e6762190e5b3d3d6b2a96ddb8fb9eb578e6e5d704df27939498946bb`. Base
  `0e1783d6947a`, built from a detached worktree with the same toolchain
  (TheRock 10.0.0), SHA-256
  `1a96537e83371b456f7c0d0f7b411ba7cd3ead1d7183f842b3b7130dcb55ac55`. Both
  runtimes have the same DLL set hash (`d307ac209b4f`).
- GPU preset tests pass: `qwen38_flash_next.projection_ops` (includes #707's
  new per-stream arena cases), `qwen38_flash_next.blaslt_ops`, and the three
  platform tests.
- Matched first-request control, varied 11,036-token prompt, AR and MTP, reuse
  and no-reuse, two ABBA arm pairs, fresh process per arm: **passed**. Every
  gated phase is `same`; MTP first decode is 51.92-53.33 ms on both sides and
  AR 42.62-44.08 ms, so #707 does not repeat the #699 first-decode pattern.
  The `cache_snapshot_ms` cells that move are reported `within noise` with
  payloads and 14.9-20.9 GB/s, as defined in
  [the procedure](#reproduce-the-first-request-control). All arms return `ACK`
  with identical prompt, cache and draft work.
- `diff-guard.ps1`, the inventory regression gate (`-Candidate HEAD`),
  `check-docs.py`, `git diff --check` and the repository formatting check
  (631 C++ files, clang-format 21.1.8) pass.

### Live checks and limits

- `PrefaultMappedRange` has one live observation, through the DFlash2 loader
  (its callers are the DFlash2, MiniMax and DeepSeek loaders, not Flash-Next).
  The head HIP `gufo` (`4e2ab445e676`) served Qwen 27B Q4_K_XL with the Q4_K_M
  DFlash2 draft, 8192 context, one session: the load completed in 12.0 s through
  the `draft_weights` phase and a greedy 120-token request drafted 103 of 103
  tokens over 16 rounds (41.3 tokens/s, first token 683 ms). The log has no
  prefault event, so this shows the path loads real weights without error, not
  its speed or fault handling. It was not compared with base, the weights were
  probably already cached, and the server was stopped with `taskkill /F`.
  MiniMax and DeepSeek loads were not run (`dflash2-live/` in the evidence).
- The Windows plan-database publication (`MoveFileExA`) is covered by
  `hipblaslt_plan_cache_test` but was not observed in a live server.
- The hosted Linux and Windows gates passed on `f9093207` (draft PR #88). The
  GPU functional suites and the standard pp2048/tg128 benchmark were not run for
  this layer.
- Pre-existing and unchanged: `compat/win32/posix.cpp`'s
  `madvise(MADV_POPULATE_READ)` has the same `__try`-around-loads pattern and,
  built with this toolchain, crashes on a faulting page instead of returning
  `EFAULT` (reproduced in a standalone probe). #729 removes that path from
  `PrefaultMappedRange`; the shim's other callers are not changed here. Draft PR
  #89 fixes the shim separately.
- No full numerical sweep, quality benchmark or complete Windows performance
  qualification was run for this layer.

## October 24, 2026: PR #703

Status: **imported as `4713d367` and merged into `windows-main` under the
`f4384d51` merge while its first-prompt timing comparison was still
`inconclusive`**. Correctness and expected work pass everywhere, and no gated
phase is slower in every repeat. The unsettled cells are the memcpy-bound
cache-snapshot phase and one MTP decode cell, which an unchanged-binary
control reproduces at the same magnitude with no code difference, so no timing
oracle pass is claimed for them. This entry records the merge after the fact.

- Windows base: `1bd5de2e4a3ec30b1df1237587c16827a9bcc802` (PR #83 merged,
  plus the DeepSeek V4.1 SSD streaming plan).
- Previous official ancestor: `7c8196527ad02ac4c585a32b1131fab7e70509d0`
  (official #711).
- Imported official head: `1167a94475ad888534a99c9fb72401636cd9f7e7`.
- Import commit: `4713d367422302902d846595a24ec7b91ce069b4`, a merge of
  `1bd5de2e` and `1167a944`. It reaches `windows-main` through `f4384d51`
  (PR #85), which was merged at the same minute; PR #84 itself is marked
  merged. The first-parent chain therefore contains no dedicated #84 merge
  commit, while both official parents remain ancestors of `windows-main`.
- Scope: #703 only.
  [#713](https://github.com/gufo-org/gufo/pull/713) and later commits are
  outside this layer and follow in
  [the #714/#713 entry](#october-24-2026-pr-714-and-713).
- Evidence ([evidence archive](#evidence-archive)): `sync-703-2026-10-24/` and
  `sync-noise-floor-2026-10-24/`.

| PR | Upstream change | Merge SHA |
| --- | --- | --- |
| [#703](https://github.com/gufo-org/gufo/pull/703) | perf(qwen38-flash-next): price unseeded sampled MTP drafts at the decoding occupancy | `1167a94475ad888534a99c9fb72401636cd9f7e7` |

### Merge review

The import merges cleanly. Upstream changes `mtp_costs.hpp`, `mtp_policy.hpp`
and `engine.cpp` costing code plus `mtp_sampling_test.cpp`; the fork keeps its
#699 revert in `engine.cpp`, which is why that file still differs from
official. Nothing Windows-specific is involved and no shared-edit file is
touched.

### Timing qualification

Matched first-request control, two ABBA arm pairs per mode, varied 11,036-token
prompt, fresh process per arm. Every arm loads the same model, returns `ACK`,
reports zero reused tokens, does identical prompt/draft work, and stops
gracefully with exit code 0. Base is `538a322e19ae` (`1bd5de2e`), candidate is
`2bdbc626f201` (`4713d367`).

| Mode/request | Base prefill (ms) | Candidate prefill (ms) | Base/candidate wall (ms) |
| --- | --- | --- | --- |
| AR reuse | 6466.72, 6252.23 | 6335.07, 6264.79 | 6603.32/6415.84 vs 6468.02/6378.43 |
| AR no-reuse | 6111.55, 6107.36 | 6101.19, 6104.75 | 6188.45/6158.52 vs 6176.43/6173.04 |
| MTP reuse | 6601.85, 6524.59 | 6494.09, 6487.25 | 6781.08/6693.97 vs 6650.95/6673.00 |
| MTP no-reuse | 6326.67, 6336.19 | 6319.90, 6335.76 | 6396.71/6420.57 vs 6396.30/6409.01 |

Prefill, TTFT, wall, queue and restore are `same` in every cell. The comparison
returns `inconclusive` for four gated cells:

| Mode/request | Phase | Base (ms) | Candidate (ms) | Verdict |
| --- | --- | --- | --- | --- |
| AR reuse | cache_snapshot_ms | 73.32, 61.14 | 58.06, 50.08 | faster |
| AR no-reuse | cache_snapshot_ms | 41.68, 30.22 | 38.66, 44.57 | noisy |
| MTP reuse | decode_ms | 57.96, 53.48 | 54.61, 53.42 | noisy |
| MTP reuse | cache_snapshot_ms | 69.76, 79.92 | 66.21, 53.66 | faster |
| MTP no-reuse | cache_snapshot_ms | 36.79, 47.13 | 39.25, 39.78 | noisy |

`cache_snapshot_ms` is a ~0.54-1.10 GB device-to-host capture, not a scheduled
phase, and `cache_snapshot_bytes` is byte-identical between the two binaries in
every cell (1,070,551,172 and 544,091,652 for AR, 1,104,736,388 and 570,323,204
for MTP), so the transfer does the same work. The implied throughput ranges
from 12.1 to 21.4 GB/s across the sixteen arms, and the disk enqueue stays
below 0.01 ms. The phase is pageable-copy bound while the pinned capture
([#688](#pr-688-windows-dflash2-continuation-latency)) remains deferred.

An unchanged-binary control settles the attribution: with `2bdbc626f201` on
both sides and byte-identical DLL sets, `compare-phases.py` reports the same
class of cells as noisy, with the same magnitude and no code difference.

| Mode/request | Phase | Arm A (ms) | Arm B (ms) | Spread | Verdict |
| --- | --- | --- | --- | --- | --- |
| AR reuse | cache_snapshot_ms | 82.96, 54.27 | 66.82, 55.57 | 53% | noisy |
| AR no-reuse | cache_snapshot_ms | 33.61, 43.73 | 37.05, 42.28 | 30% | noisy |
| MTP reuse | cache_snapshot_ms | 65.20, 54.87 | 68.75, 53.31 | 29% | noisy |
| MTP no-reuse | decode_ms | 55.41, 51.58 | 52.28, 51.83 | 7% | noisy |

The replay also flagged a different subset of the same jitter-prone cells than
the matched run did, which is the signature of an instrument whose repeatability
(29-53%) is wider than its 3 ms/5% floor rather than of a code change. Neither
run produces a `slower` verdict in any repeat and neither has a correctness
problem.

### Live checks and limits

- The comparison status is left as `inconclusive`. It is not relabelled, no
  tolerance is widened and no averaging is applied, so the phase remains
  unqualified. Merging on this evidence is a maintainer decision, recorded here
  as such.
- `cache_snapshot_ms` and `cache_restore_ms` cannot be resolved by this
  workload on Windows while the snapshot copy is pageable. Do not treat a
  single noisy cell there as a regression: reproduce it with an
  unchanged-binary control, and read the byte count and the implied throughput
  before reading the verdict.
- The hosted gates qualified the #714/#713 layer that follows, not this one;
  no hosted run covered `4713d367` by itself.
- No full numerical sweep, quality benchmark or complete Windows performance
  qualification was run for this layer.

## October 24, 2026: PR #714 and #713

Status: **merged as `f4384d51` by
[PR #85](https://github.com/thomas9120/gufo-windows/pull/85)**. All six
executed hosted gates passed on `563c0be4` (three functional jobs skipped), and
the merged tree is identical to the tested candidate `d82b6cde`. #714 touches
the Flash-Next prefill indexer GEMM, so its live timing controls are part of
this layer. #713 replaces the fork's local console handler with the upstream
shutdown leaf.

- Windows base: `4713d367422302902d846595a24ec7b91ce069b4` (official #703,
  recorded in [the #703 entry](#october-24-2026-pr-703), which also carries the
  unresolved first-prompt comparison that `4713d367` inherited).
- Previous official ancestor: `1167a94475ad888534a99c9fb72401636cd9f7e7`.
- Imported official head: `79c2dcc56f00c69d4085e52bde6d290b74a99ccd`.
- Integration merges: `9f15b369` (through `6c8b2ff4`, #714) and `52dc136f`
  (through `79c2dcc5`, #713).
- Scope: #714 and #713 only. #722 and later commits, including the official
  0.22.0 release commit `7b1bf049`, are outside this layer.
- Evidence ([evidence archive](#evidence-archive)): `sync-714-713-2026-10-24/`.

| PR | Upstream change | Merge SHA |
| --- | --- | --- |
| [#714](https://github.com/gufo-org/gufo/pull/714) | fix(qwen38-flash-next): sum BF16 indexer projections in K order for every token | `6c8b2ff4c7d6c7c2e00835f84e6d4b4cee1c7226` |
| [#713](https://github.com/gufo-org/gufo/pull/713) | feat(platform): add the shutdown_signal leaf | `79c2dcc56f00c69d4085e52bde6d290b74a99ccd` |

### Merge review

#714 merges cleanly; `kernels/rocm/kernels.hip.cpp` and `kernels.hpp`
auto-merge against the #699 revert and the revert stays intact (no
`SampledMtpCandidates`, `LogitCandidate`, `VerificationCandidateTileKernel` or
other recorded identifier is present). The change deletes the `own_bf16` plan
gate and the `DenseF16GEMM` StaggerU rotation, so every BF16 indexer projection
now takes the fork-independently fast dense kernel with plain K order. No
Windows-specific code is involved.

#713 has one conflict in `src/cli/serve/http_server.cpp`: adopt upstream's
`platform::ShutdownSignalGuard` and delete the fork's local `ShutdownSignals`
sigaction pair and `RequestConsoleShutdown` handler. The upstream leaf already
implements the Windows console path natively (`CTRL_C`/`CTRL_BREAK` mapped onto
`SIGINT`, hold-and-drain for `CTRL_CLOSE`/logoff/shutdown), so the resolution
shrinks the maintained difference instead of adding a second handler. The
`socket.hpp` include stays (`SocketHandle`/`kInvalidSocket`); upstream's
`net.hpp` include is not needed because its leaf remains unreferenced here.
`signal(SIGPIPE, SIG_IGN)` becomes `platform::IgnoreSocketPipeSignal()` and the
accept loop calls `platform::NotifyShutdownHandled()` after `stop()`. Both new
leaf files are byte-identical to official, and the root `CMakeLists.txt` source
addition auto-merges.

### Compatibility and validation

| Contract | Outcome |
| --- | --- |
| Cached concurrent n-gram reads | Reviewed/unchanged: no n-gram, loader or read-flag change; the first-prompt control exercises the cold path in all eight arms. |
| WDDM admission budgets | Reviewed/unchanged: no admission helper, `hipMemGetInfo` caller or host-budget change. |
| Pinned memory and transfer lifetime | Reviewed/unchanged; #688 pinned capture remains deferred and its identifiers stay absent. |
| Sockets and shutdown | Validated: the leaf owns the signal and console paths, the Windows CPU shutdown checks pass, a direct `CTRL_CLOSE` probe drains an in-flight request, and all eight HIP server arms stop gracefully. |
| Filesystem identity, privacy and failures | Reviewed/unchanged: native CPU filesystem, store and identity checks pass. |
| GPU queue policy | Reviewed/unchanged: CPU startup-policy checks pass; server startup leaves `GPU_MAX_HW_QUEUES` untouched. |

Completed checks:

- Native Windows CPU configure/build and **16/16 CTests pass** (20.76 s),
  including `win32_server_shutdown_test` and the Winsock transport checks.
- Native HIP `gufo` builds at `52dc136ff6aa`; SHA-256
  `5173d1258d07b01b2df4cc8151b928a82d72c4f1679e5e159b82049020036036`.
- `qwen38_flash_next.blaslt_ops` and `qwen38_flash_next.projection_ops` pass on
  `gfx1151`. `qwen38_flash_next_dense_gemm_bench` reports identical batches at
  every offset for the four BF16 indexer shapes ("rows changed with their batch
  offset at 0 of 5 offsets") and 3.2-3.8e-05 maximum deviation from the library
  kernel, with the own kernel 3.6-4.5x faster.
- Matched first-request control on a varied 11,036-token prompt, AR and MTP,
  reuse and no-reuse, two ABBA arm pairs against the #703 candidate binary: no
  gated phase regresses, prefill is 0.6-1.9% faster and decode is unchanged.
  All eight arms return `ACK` with identical prompt/cache/draft work and stop
  gracefully with exit code 0.
- Standard pp2048/tg128 spots (two per binary and mode) show unchanged decode
  and 0.4-0.5% higher prefill throughput. They do not qualify a speedup.
- `CTRL_CLOSE` probe: posting `WM_CLOSE` to a private console sends the new
  console event, the server logs `event=shutdown_requested signal=15`, drains
  the in-flight request and exits, where the previous fork handler returned
  `FALSE` and let the default handler terminate it.
- Documentation, maintained-difference (`diff-guard.ps1`), sync-tool, inventory
  regression gate and `git diff --check` checks pass.
- Hosted gates on `563c0be4`: the shared formatting and documentation check,
  the Linux CPU contracts, the native Windows CPU contracts, the upstream
  difference guard, the installer and the browser-launcher checks pass. The
  GPU functional jobs are skipped, as before.

### Live checks and limits

- The hosted gates qualify only the checks they run; the Flash-Next timing,
  GPU/model and console-close results above are local Windows evidence.
- `gufo bench --validate-prefill 512` fails its own cosine gate on **both**
  binaries: the candidate reports rmse `0.778032`, cosine `0.978565` against
  the unchanged `0.979` limit and max error `4.84346`, and the #703 base fails
  the same check and exits early. The failure is inherited and visible; it is
  not attributed to #714 and no oracle pass is claimed. The base binary's
  printout rounds to two decimals (`0.78`/`0.98`/`4.84`), so this probe cannot
  separate the two revisions' exact values.
- The comparison status is `inconclusive` because four `cache_snapshot_ms`
  cells are noisy, matching the retained #703 comparison. Every observation is
  kept; nothing is averaged or relabelled. Replaying the retained
  `control.json` with the [memcpy calibration](#reproduce-the-first-request-control)
  added after the merge reports those four cells as `within noise` with their
  payloads and 12.4-18.4 GB/s throughput and the run as **`passed`**; the merge
  itself was made on the `inconclusive` output, and the earlier verdicts stay
  in the record above unchanged.
- No full numerical sweep, quality benchmark or complete Windows performance
  qualification was run for this layer.

## October 23, 2026: PR #677

Status: **merged** by PR #79 as `ad3696f5`. Local Windows checks passed, and
all six executed hosted gates passed on `bc6f8c6e` (three GPU jobs skipped).

- Windows base: `041772cbbca43953b5ba6b5322a18118ffe5bdba` (#78 merged).
- Previous official ancestor: `b0eb5d476d07b659fb0d6a448b56f66d5420a113`.
- Imported official head: `8a79230617490ff374b38edc002a8e68d241cf68`.
- Integration merge: `07edb498148c9db65213120aa9a967122cff0536`.
- Scope: #677 and its predecessor, the official 0.21.0 release commit
  `7110c795` (changelog, `version.txt` and release manifest, imported unchanged).
  #711 and later commits are outside this layer.
- Evidence ([evidence archive](#evidence-archive)): `sync-677-2026-10-23/`.

| PR | Upstream change | Merge SHA |
| --- | --- | --- |
| [#677](https://github.com/gufo-org/gufo/pull/677) | fix(cache): free RAM before writing oversized checkpoints to disk | `8a79230617490ff374b38edc002a8e68d241cf68` |

### Merge review

One conflict in `ComponentTextCache::Capture()`. Upstream's new over-RAM
branch compares against `cache.budget`, which exists only with the deferred
[#688 pinned budget](#pr-688-windows-dflash2-continuation-latency). The
resolution keeps #677's block, including the `refused`/`failed` logging and the
rethrow, and keeps the fork's `cache.ledger.Limits().ram_bytes` limit, as the
neighbouring snapshot reservation and planned-capture checks already do. No
#688 identifier returns.

Clean merges reviewed: deferred, largest-first staging allocation in
`CaptureDurable` with reclamation that protects the source checkpoint and this
turn's edit boundaries; the retention victim guard; the fake adapter's
`rows_per_chunk`; and the new retention and component tests. The new component
test's `/tmp` `mkdtemp` template already resolves through the Windows shim. The
functional README keeps the Windows and #699 paragraphs and adds the reclaim
case. The two inventory review items (#688 and #699 shared files) are covered
above; neither reintroduces reverted code.

### Compatibility and validation

| Contract | Outcome |
| --- | --- |
| Cached concurrent n-gram reads | Reviewed/unchanged: no model I/O or n-gram change. |
| WDDM admission budgets | Reviewed/unchanged: device budgets are untouched. The over-RAM path is bounded by the host RAM ledger, verified at a 256 MiB cache below. |
| Pinned memory and transfer lifetime | Validated: over-RAM capture borrows live rows and stages private state; a 1.6 GB checkpoint publishes and restores with identical output across base/head. |
| Sockets and shutdown | Native CPU checks pass; every live server stopped cleanly. |
| Filesystem identity, privacy and failures | Validated: Windows NTFS rebuildable store (`disk_cache_platform platform=windows`) publishes, restores and restarts; native CPU store checks pass. |
| GPU queue policy | Reviewed/unchanged. |

- Native Windows CPU build and **16/16 CTests pass**, including
  `cache_retention_test` with the new protected-source case.
- `component_text_cache_test` still stops at the known, pre-existing
  `OrphansLeaveBeforeCheckpoints` DACL assertion (#688 entry) before #677's
  cases. An ignored harness compiled the unchanged upstream test with only
  `OverRamCaptureStagesPrivateStateUnderPressure(false/true)`; both pass.
- HIP `gufo` builds at `07edb498`; SHA-256
  `5929ab89ac4c59193b7861de93b56d49581eb5b4af58e87ea59cc9c8abced89b`.
  Base is the #78 production binary `c8e66f75...`.
- Native form of upstream's `publication_wait.py --case reclaim` (the upstream
  runner needs the Linux `LD_PRELOAD` disk gate, so it waits for the real
  publication instead): Flash-Next Q4_K_XL/shared-Q8 MTP, context 65,536, one
  session, 256 MiB RAM cache, 55,111-token deep prompt.
  - Base reproduces the bug: the deep capture is refused
    (`reason=byte_capacity`), nothing over RAM publishes and the retry
    re-prefills 55,073 tokens (TTFT 33.0 s).
  - Head reclaims a retained RAM checkpoint (`action=2 reason=1`), publishes
    the 55,106-token, 1,646,239,144-byte checkpoint and restores it from disk
    with 19 prefill tokens (TTFT 1.50 s). No `capture_failed`.
- At a 1 GiB cache (no reclaim needed) base and head both publish and restore.
  The first head/base pair differed by +166 ms in `cache_restore_ms` only;
  two further alternating pairs measured +0.8%/+2.7% restore and +0.9%/+3.0%
  TTFT, within the 5% limit. Restore timing drifts upward across the session
  for both binaries.
- Output: seed, deep, retry and cold responses and their draft counts are
  identical across all eight base/head runs. The retry's reasoning text differs
  from the cold control's in every run, including base retries that never touch
  disk; the final answer matches. This pre-existing prefill-split difference is
  why the upstream runner's exact retry/cold assertion is not a Windows gate here.
- Bounded MTP `cache_startup.py --case ram` and `--case disk` pass on head:
  2,294-token cold prompts, zero-prefill retries and a 7-token-prefill disk
  restart restore, with matching output and 19/16 drafts each. These runs set
  `PYTHONUTF8=1` because upstream harness provenance reads non-ASCII test files
  with the locale codec.
- Formatting checks 622 C++ files. Inventory with `-Candidate HEAD` and the
  maintained-difference guard pass; #688/#699 identifiers stay absent.
- Pending: upstream `publication_wait.py --case reclaim` itself (Linux-only
  fault library), Linux/hosted gates, and Qwen 27B AR/DFlash2 reclaim. No
  full model sweep or speedup claim.

## October 23, 2026: PR #688, pinned capture deferred

- Windows base: `d812ebab17f604684fef3513eb2d31560577d669` (#77 merged).
- Previous official ancestor: `3aa068b419e6272482298c1c6daccafb122764fa`.
- Selected official head: `b0eb5d476d07b659fb0d6a448b56f66d5420a113` (#688 only).
- Fetched official/main: `de43b8a047735fb296a5d4f1218f1f628cbff5ac`; later changes
  are outside this layer. No release/version changes.
- Conflict-free integration merge: `225ec080`; explicit optimization revert:
  `432163e9`; isolated upload-failure cleanup retained by `77a58de7`.
- [Fork PR #78](https://github.com/thomas9120/gufo-windows/pull/78) preserves
  ancestry. The [deferral record](#pr-688-windows-dflash2-continuation-latency)
  and machine-readable guard prevent automatic reintroduction. #699 stays reverted.

The final production difference from the Windows base is only the DFlash2
context-upload scope guard. Its unchanged upstream test delays a host upload,
injects a recoverable device-copy error, overwrites caller data immediately on
return, checks the uploaded bytes and verifies recovery, for pageable and pinned
sources. A Windows-only test-process HIP import hook replaces ELF linker wrapping;
it is absent from production binaries. Linux keeps the upstream fixture and hook.

All four full-import candidate profiles individually pass `long-context`,
text/thinking/tool/image cancellation, exact RAM replay and disk restart/spacing;
actual drafts are observed in DFlash2 and MTP. These correctness results do not
clear the failed matched DFlash2 timing/continuation comparisons. Flash-Next
AR/MTP match baseline output/work but their timing remains inconclusive.
The full-import CPU 17/17, numerical prefill, native cancel/resume, WDDM,
pinned buffer/transfers and Flash cross-slot probes pass. Those results refer
to the rejected optimization; final-subset checks are recorded below.

The extra broad component-cache fixture fails at its orphan assertion because
`std::ofstream` creates an unprotected DACL; existing Windows privacy checks
exclude that file from deletion. Original failure, ACL and source evidence are
retained. Upstream pinned-budget assertions passed independently, but their
temporary native adapter is removed with the optimization.

Final-subset validation, built clean at `852e2455` with TheRock 10.0.0/Clang
23.0.0, MSVC 14.51.36231 and SDK 10.0.26100.0:

- Native CPU build and **16/16 CTests pass**; HIP executable and affected test
  targets build. The temporary pinned-budget target is removed with the
  optimization, so its earlier 17-test run is not the final gate.
- Upload-lifetime fixture passes for pageable and pinned sources: no upload
  remains pending at failed return, original source bytes are preserved and
  subsequent injection recovers.
- Numerical prefill/captured-row checks and exact AR/DFlash2 native cancelled
  prefill resume pass. The latter retains the same eight-token frontier.
- Bounded Qwen DFlash2 HTTP RAM smoke passes at context 8192, one session and
  effective 1 GiB cache: cold 2,294/2,294 prompt/prefill tokens; retry reuses all
  2,294 with zero prefill. Both responses match and each proposes 18/accepts
  17 drafts. Private server shutdown is clean.
- Standard `gufo bench -p 2048 -n 128 -r 1 -v` AR/DFlash2 spots complete on
  baseline and final subset, at one common executable path. All four output
  hashes match (`095434b2...`); both DFlash2 arms report acceptance 0.439.
  These single-repetition spots do not qualify a speedup or full performance.
- Formatting checks 622 C++ files. Docs/dependencies, maintained-difference and
  sync inventory checks pass; all four #688 and six #699 excluded identifiers
  remain absent, and the recorded official head/reverts remain ancestors.

Production executable SHA-256:
`c8e66f755e4af759be88500ea253cc2a532f740c3989131a41c1b23d52861740`.
Later documentation/guard records do not change that production source.
Hosted qualification is pending on the final PR head. Evidence
([evidence archive](#evidence-archive)): `sync-688-2026-10-23/`; no full model sweep, speedup or full Windows
performance qualification is claimed.

## October 23, 2026: PR #709

Status: **local Windows checks and six executed hosted gates passed on
`96a67c74`; merged by PR #77 as `d812ebab`**. Three GPU/workflow jobs were skipped.

- Windows base: `4eb2aedd572be9b54125f4e49e8de04e216872a1` (PR #76 merged).
- Previous official ancestor: `2947624b9e65f52d4b4fdd96297f39e040a0ed24`.
- Imported official head: `3aa068b419e6272482298c1c6daccafb122764fa`.
- Integration merge: `be07d64b63ce5ecb9eab0c2d16d80a9e48eec668`.
- Scope: #709 only; the later upstream commits, including release changes,
  are outside this layer.
- Evidence ([evidence archive](#evidence-archive)): `sync-709-2026-10-23/`.

| PR | Upstream change | Merge SHA |
| --- | --- | --- |
| [#709](https://github.com/gufo-org/gufo/pull/709) | Native OS page-size and available-memory leaf | `3aa068b419e6272482298c1c6daccafb122764fa` |

### Merge review

One conflict in `HostAvailableBytes()`: adopt the upstream
`platform::AvailableMemoryBytes()` call while retaining the Windows early
return before Linux CMA/cgroup refinements. Upstream drops `<unistd.h>`, so
keeping the old fork helper call would also leave its declaration unavailable.
The native leaf uses the same `GlobalMemoryStatusEx` API and result as the
previous Windows helper. Host physical RAM remains separate from WDDM device
headroom, and host reserve calculations are unchanged.

The root CMake source-list addition merges cleanly and was reviewed. Both new
`os_info` files remain byte-identical to official. The existing Windows-owned
host test now checks the page size against `GetSystemInfo` and the new memory
query against surrounding native observations, alongside its existing
snapshot-budget and ceiling checks. No inference, n-gram or transfer code
changes. PR #699 remains reverted and its forbidden identifiers stay absent.

### Compatibility and validation

| Contract | Outcome |
| --- | --- |
| Cached concurrent n-gram reads | Reviewed/unchanged: reopening/read flags and model paths are untouched. |
| WDDM admission budgets | Device helper reviewed/unchanged. Host page/memory queries and reserve calculations pass native OS-oracle checks; public MTP serving honors the requested 1 GiB RAM cache. |
| Pinned memory and transfer lifetime | Reviewed/unchanged; the bounded MTP RAM retry replays exactly with full prompt reuse. |
| Sockets and shutdown | Native HTTP/WebSocket/console checks pass in the CPU gate; the live HIP smoke server exits cleanly. |
| Filesystem identity, privacy and failures | Native CPU filesystem/store checks pass; legacy disk guards are retained. RAM-only startup does not populate the durable model-identity cache. |
| GPU queue policy | Reviewed/unchanged; CPU startup-policy checks pass and native HIP serving starts successfully. |

- Native Windows CPU configure/build and **16/16 CTests pass**.
- Native HIP `gufo` builds at `be07d64b63ce`; its SHA-256 is
  `b2df4482c6b1601f631b005841087af55115cdb255b8fb84cc2c8f9689901165`.
- Bounded MTP RAM startup/retry passes with actual drafting and the requested
  cache capacity; [model evidence](models/qwen3.8-flash-next/WINDOWS.md#os-info-adoption-october-23-2026).
- Formatting checks all 620 C++ files. Documentation, dependency inventory,
  maintained-difference and reverted-identifier checks pass; official ancestry
  is preserved.
- Linux/repository and hosted Windows checks remain pending until the sync
  PR completes. This platform refactor does not refresh numerical sweeps or
  inference benchmarks; the previous timing limits remain visible.

## October 23, 2026: PR #711

Status: **imported and locally qualified on `d87a8ae14a`; the hosted
Linux/repository and Windows CPU gates passed on `fb8f87a3`; draft
[PR #82](https://github.com/thomas9120/gufo-windows/pull/82) makes official
ancestry visible and waits for a merge-commit integration**. The layer is
additive: no production source changed, so no model, prefill or cache timing
work is claimed or required. The following record-only commits do not change
that production source.

- Windows base: `5606d1c67503f28e3a69620ca9be825561efc059` (PR #81 merged).
- Previous official ancestor: `8a79230617490ff374b38edc002a8e68d241cf68`.
- Imported official head: `7c8196527ad02ac4c585a32b1131fab7e70509d0`
  (upstream's squash merge of #711; its only parent is the previous ancestor).
- Integration merge: `d87a8ae14afd321cadac18b961356842061f83dc`.
- Scope: #711 only. The later upstream commits (for example #713 shutdown
  signals, #729 publish/prefault, #734 and #738 mapped files, #739 draft
  selection, #747 Nix caching) are outside this layer.
- Evidence ([evidence archive](#evidence-archive)): `sync-711-2026-10-23/`.

| PR | Upstream change | Merge SHA |
| --- | --- | --- |
| [#711](https://github.com/gufo-org/gufo/pull/711) | feat(platform): add the net leaf | `7c8196527ad02ac4c585a32b1131fab7e70509d0` |

### Merge review

Upstream adds the `src/core/platform/net.{hpp,cpp}` leaf and rewrites the
socket call sites in `http_server.cpp`, `websocket.cpp` and two CLI tests to
use it. This fork already has its own socket layer,
[`socket.hpp`](../src/core/platform/socket.hpp), so the merge decides which
layer owns the call sites: the fork's `gufo::platform` wrappers stay, and the
upstream leaf is imported byte-identical and left unreferenced for a later
slice.

- 45 conflict hunks across four files
  (`http_server.cpp` 19, `http_server_test.cpp` 18,
  `audio_websocket_test.cpp` 5, `websocket.cpp` 3), all of them the same
  mechanical choice. Each discarded hunk was reviewed individually; they
  contain only layer swaps:
  `MSG_NOSIGNAL` send to `net::SendNoSignal`, `::poll` to `net::PollSocket`,
  listener `fcntl(O_NONBLOCK)` to `net::SetNonBlocking`, the 120 s `timeval`
  pair to `net::SetSocketTimeouts`, `TCP_NODELAY` and the 5 s send timeout to
  `net::SetNoDelay`/`net::SetSendTimeout`, `::close` to `net::CloseSocket`,
  and the tests' `int fd`/`fd >= 0`/`net::` helper swaps.
- Reasons for keeping the fork's layer: upstream's send, receive and poll
  wrappers do not map WinSock errors to `errno`, so the existing
  `EINTR`/`EAGAIN` checks would stop working on Windows; it has no
  cancel-on-shutdown counterparts to `ShutdownSocket`, `StopSocketReads` and
  `CloseConnection`, which back the validated Ctrl+C/Ctrl+Break and orderly
  close contracts; and its call sites keep handles in `int`, which narrows a
  pointer-sized `SOCKET`. `net::Socket` itself is already width-correct, so
  these are call-site gaps rather than a reason to reject the leaf.
- `websocket.cpp` keeps its `<netinet/in.h>`, `<netinet/tcp.h>` and
  `<sys/socket.h>` includes: upstream deleted them because `net.hpp` supplies
  those declarations, but the retained fork wrappers need them and this
  translation unit does not include `net.hpp`. The Windows shims behind them
  are unchanged.
- `audio_websocket_test.cpp` and `http_server_test.cpp` had one pure-deletion
  hunk each (upstream's `namespace net = gufo::net;` alias). Both files are
  marker-enforced in [`shared-edits.json`](../tools/windows/shared-edits.json),
  and a pure deletion cannot carry a marker, so each alias became
  `// WINDOWS: keep native Winsock handles; gufo::platform wrappers replace
  net::.` Those two comment lines are the entire source delta of this sync
  against the Windows base.
- Clean merges reviewed: the root `CMakeLists.txt` source-list line adds
  `src/core/platform/net.cpp` to `gufo_core`; the fork's Windows overrides in
  `cmake/Windows.cmake` are untouched. `net.hpp` and `net.cpp` are
  byte-identical to official (blobs `81679b39`, `588a2b20`) and now compile on
  Windows in both presets, but no fork code references them yet.
- Follow-up: adopt the upstream leaf, or the parts of it that fit, once it
  covers native-width call-site handles, `errno` mapping and
  cancel-on-shutdown; see the
  [upstream friction TODO](todo.md#1-upstream-portable-fixes-to-shrink-the-48-file-src-delta-defer-this-for-now).

### Compatibility and validation

| Contract | Outcome |
| --- | --- |
| Cached concurrent n-gram reads | Reviewed/unchanged: no engine, loader, n-gram or I/O path is edited; PR #699 stays reverted and its identifiers are absent. |
| WDDM admission budgets | Reviewed/unchanged: no device-memory or budget code; the live HIP server starts and stops normally. |
| Pinned memory and transfer lifetime | Reviewed/unchanged: no pinning or transfer code; PR #688 stays deferred and its identifiers are absent. |
| Sockets and shutdown | Validated: production paths keep the fork's layer. Native CPU gate passes `http_server_test`, `audio_websocket_test` and `win32_server_shutdown_test` (real Ctrl+C/Ctrl+Break during idle, active and partial requests), and the live HIP server exits cleanly on Ctrl+Break. |
| Filesystem identity, privacy and failures | Reviewed/unchanged: native filesystem and store checks pass unchanged. |
| GPU queue policy | Reviewed/unchanged: startup-policy checks pass and native HIP serving starts. |

- Native Windows CPU configure/build (176 targets) and **16/16 CTests pass** in
  18.3 s.
- Native HIP `gufo` builds at `d87a8ae14afd` (274 targets, TheRock 10.0.0); its
  SHA-256 is
  `64dfde137bb49232a519e13586f372fd9391ee141461df3e0005e7e59c50f891`.
- Live HIP smoke: ready in 26.703 s, `/health` ok, one buffered and one
  streamed completion (26 SSE events, terminal `data: [DONE]`), Ctrl+Break
  shutdown in 1.264 s with exit code 0.
- Formatting checks all 624 C++ files with clang-format 21.1.8. Documentation
  (101 files, 654 links), inventory, maintained-difference and
  reverted-identifier checks pass; `git diff --check` is clean and official
  ancestry is preserved.
- Hosted gates on `fb8f87a3` (draft PR #82): CPU contracts & repository
  checks (hosted Linux/Nix) 8m14s, Native CPU contracts 6m01s, Upstream
  difference guard 1m08s, Installer checks 46s, Browser launcher checks 51s and
  Conventional Commit title 5s. The hosted Linux build compiles the leaf's
  POSIX branches, which have no local build on this host. The advisory devlab
  functional checks were skipped because they need maintainer authorization;
  they do not gate this layer.
- No numerical sweep or inference benchmark is refreshed: this layer changes no
  model, prefill or cache behavior, so the previous timing limits stay as
  recorded. Integrate with a merge commit, not a squash or rebase, to keep
  official ancestry on `windows-main`.

## October 23, 2026: PR #350 qualification follow-up

Status: **no confirmed YaRN regression after matched controls; timing remains inconclusive**.
PR #75 merged as `a63f2b4e597a2ece22f817ec6164ff96149abdfe` while local
qualification was still running. The final October 22 record is
`sync-350-2026-10-22/FINAL-VALIDATION.md` in the
[evidence archive](#evidence-archive); follow-up commands,
hashes and per-request results are in `sync-350-2026-10-23/`.

The original two API pairs per mode used equal effective 8 GiB RAM budgets.
They preserve outputs and cache/prefill work, but fail two AR timing cells and
seven MTP cells. Later October 22 controls had unequal effective budgets as
host memory availability changed. One MTP pair consequently differs in warm
image-prefix reuse (13/5 candidate prefill tokens versus zero on baseline).
Those controls cannot clear the original matched failures.

On October 23, the retained executable hashes still match. Fresh baseline
controls verify the full 8 GiB at startup and restart: AR restore timing becomes
inconclusive, while three MTP total-duration cells remain outside the gate.
Decode time and actual token/draft work agree. An instrumented completion probe
and a byte-identical candidate under a different filename vary in latency;
these are diagnostic controls, not qualified fixes. A same-path baseline/head
ABBA control also reproduces the extra duration on the unchanged baseline.
Its standalone comparison flags one snapshot phase; the retained baseline
already varies from 12.30 to 30.30 ms in that exact history.

The final assessment retains all five valid matched MTP pairs, verifies their
build roles by SHA-256 across executable paths, and verifies all 143 runtime
files against the original control. It uses the unchanged upstream
`compare_runs` and `qualify` functions: **577 timing cells pass, 283 remain
inconclusive, none is confirmed slower; output and work changes are zero**.
Clamped and instrumented runs are excluded from qualification and retained
separately. Raw reports are unmodified. Original failed comparisons remain
failed observations; the assessment adds the verified controls instead of
discarding them or averaging requests. See the
[model measurements](models/qwen3.8-flash-next/WINDOWS.md#yarn-matched-follow-up-october-23-2026).

There is no confirmed #350 blocker requiring deferral, and no inference change
or relaxed tolerance is retained. A complete Windows performance pass remains
unclaimed. PR #699 remains reverted.

The Windows functional comparison wrapper now rejects clamped requests and
different effective cache budgets before invoking the upstream comparator.
Its native-host unit checks also cover restart clamping and staging/disk
capacity differences. It preserves the original per-request 5% and 3 ms gates
and retains rejected evidence.

## October 22, 2026: PR #350

Status: **merged; correctness evidence completed, Windows timing unqualified**.
See the October 23 follow-up above for the latest investigation status.

- Windows base: `d10a852f0f094d926128ecf2e9dd112cae0c4a8e` (PR #74 merged).
- Previous official ancestor: `53ebb51ed0c0b24dbe7c1e35dce6c97d82740bfe`.
- Imported official commit: `2947624b9e65f52d4b4fdd96297f39e040a0ed24`.
- Integration merge: `8170cfc855484da939df61cbcf4c31d125cde772`.
- Scope: #350 only. The later #709, #688, #710, #677 and #711 commits will
  follow in separately qualified sync PRs.
- Evidence ([evidence archive](#evidence-archive)): `sync-350-2026-10-22/`.

| PR | Upstream change | Merge SHA |
| --- | --- | --- |
| [#350](https://github.com/gufo-org/gufo/pull/350) | Opt-in Flash-Next YaRN context extension | `2947624b9e65f52d4b4fdd96297f39e040a0ed24` |

### Merge review

One conflict, in `projection_ops_test.cpp`: preserve the null vision descriptor
from the #699 revert and pass the new YaRN argument. Clean merges of the
executor, kernels, engine and serving options were also reviewed. #699 remains
reverted; its six forbidden identifiers stay absent.

Windows' MSVC library prints padded hexadecimal fractions in `std::hexfloat`,
breaking upstream's pinned YaRN cache identity. The Windows-only normalization
in `rope_scaling.cpp` removes that padding and passes the original test
unchanged. Linux formatting is unchanged. The shared edit is marked and listed.

The Windows-owned `win32_yarn_snapshot_test.cpp` covers checkpoint replay
without the upstream snapshot test's Linux ELF fault hooks. It checks exact
logits, tokens and actual MTP draft work, serialized replay, old executor-format
rejection/reset/recovery, and rejection of a different scaling factor.
Bitwise replay controls use matching prefill boundaries. The current executor
format changes from `QFNSNAP5` to `QFNSNAP6`; the outer session version stays 18.

### Compatibility and validation

| Contract | Outcome |
| --- | --- |
| Cached concurrent n-gram reads | Windows reopening/read flags unchanged; native n-gram checks pass. Fresh-process inference timing remains inconclusive pending controls. |
| WDDM admission budgets | Helper unchanged; native 409,600-capacity AR/MTP fixtures and public 262,145-capacity MTP serving pass without weakening admission. |
| Pinned memory and transfer lifetime | Native snapshot-copy operator, AR/MTP 4K cross-slot checks and above-native YaRN checkpoint replay pass. |
| Sockets and shutdown | Implementation unchanged; bounded native HTTP/WebSocket and real console-shutdown checks pass. |
| Filesystem identity, privacy and failures | Native implementation and model payload/factor compatibility checks pass. Scaled MTP API disk restart passes exact response replay and actual drafting. |
| GPU queue policy | Boundary unchanged; bounded native startup policy checks pass. |

Completed local checks and current limits:

- Native Windows CPU gate: **16/16 pass** (`final-cpu-ctest.txt`).
- Selected operators: eight pass initially; the original rope-policy test fails
  on MSVC padding, then passes after the normalization (`head-operator-ctest.txt`,
  `fixed-rope-ctest.txt`). No GPU kernel change was needed after those passes.
- Full-model numerical/continuation evidence and per-request timing details are
  recorded in the [Windows model sidecar](models/qwen3.8-flash-next/WINDOWS.md).
- Final bounded YaRN fixture: AR/MTP exact replay and scaling-factor rejection
  pass (`final-yarn-snapshot-3.log`). Earlier fixture assumptions and their
  failed observations remain retained; the production restore/reset behavior
  is byte-identical to the Windows base.
- Shared formatting passes for 618 C++ files. Documentation, dependencies,
  maintained-difference and reverted-identifier checks pass.
- First-prompt control: correctness passes in all eight fresh processes;
  snapshot timing and first MTP decode have noisy cells. Overall timing is
  **inconclusive**, not passed (`cold-control-1/`). An unchanged-base MTP
  control also reports moved snapshot cells on identical binaries.
- Standard AR/MTP pp2048/tg128 spots, extended native YaRN replay and public
  scaled MTP startup/RAM retry/disk restart pass. See the model sidecar for
  measurements and scope. Both CLI opt-in refusal checks pass.
- All 14 selected API executions pass their own correctness assertions, but
  the original matched timing failures and later unequal-budget cache-work
  failure remain retained. They do not establish a performance pass.
- Six executed hosted Linux/repository/Windows CPU gates pass on `5d60b5bc`;
  skipped GPU/functional/report jobs are not counted as passes. No complete
  Linux GPU/model or Windows performance qualification is claimed.

## October 22, 2026: PR #702

Status: **candidate local checks pass; hosted qualification is recorded on the sync PR**.

- Windows base: `e416eac00b1450eb03d82165d76ebd1970ac0364` (includes PR #73).
- Previous official ancestor: `e060aeed923730b74ea3f4116c3c39de55741370`.
- Imported official commit: `53ebb51ed0c0b24dbe7c1e35dce6c97d82740bfe`.
- Integration: ordinary merge, `45bb338c2e5e42b5d99a985c65be22e05792c1fb`.
- Fetched `official/main`: `7c819652`. This import intentionally stops at
  #702 as requested; the six newer upstream commits are not included.
- Evidence ([evidence archive](#evidence-archive)): `sync-702-2026-10-22/`.

| PR | Upstream change | Merge SHA |
| --- | --- | --- |
| [#702](https://github.com/gufo-org/gufo/pull/702) | Stop the benchmark server when startup is interrupted | `53ebb51ed0c0b24dbe7c1e35dce6c97d82740bfe` |

### Merge review

No conflicts or files changed on both sides. The two imported files,
`tools/gufo/model_bench/servers.py` and `tests/tools/serving_bench_test.py`,
remain byte-identical to the recorded upstream commit. The helper now stops
its server and re-raises when readiness checking exits through an exception,
including `KeyboardInterrupt`. Review covered early process exit, readiness
timeout and the existing process-group shutdown. No engine, model, CMake,
dependency or Windows platform code changes.

The inventory finds no incoming change to #699's reverted regions. Its revert
and reintroduction requirements remain intact; the candidate check confirms
that its six forbidden identifiers remain absent.

### Compatibility and validation

| Contract | Outcome |
| --- | --- |
| Cached concurrent n-gram reads | Reviewed/unchanged: no model or I/O path changes. |
| WDDM admission budgets | Reviewed/unchanged: no admission or device-memory changes. |
| Pinned memory and transfer lifetime | Reviewed/unchanged: no allocation, transfer or snapshot changes. |
| Sockets and shutdown | Native engine paths unchanged; bounded HTTP/WebSocket and real console-shutdown checks pass. Benchmark-helper interruption cleanup passes separately under WSL. |
| Filesystem identity, privacy and failures | Implementation unchanged; bounded identity, privacy and failure checks pass. |
| GPU queue policy | Implementation unchanged; bounded native startup policy checks pass. |

Completed checks:

- `tools/windows/build.ps1 -Preset windows-cpu -Vcpkg VCPKG_PATH
  -Ninja NINJA_PATH -Jobs 4`: pass with TheRock's compiler, MSVC 14.51.36231,
  SDK 10.0.26100.0, CMake 4.4.0 and the existing pinned vcpkg manifest.
- `ctest --preset windows-cpu --no-tests=error --output-on-failure`:
  **16/16 pass**, 19.49 seconds (`cpu-build.txt`, `cpu-ctest.txt`).
- `python3 -I tests/tools/serving_bench_test.py` under WSL/Python 3.12.3:
  **pass**, including the new real-process interruption test
  (`serving-bench-wsl.txt`). This helper uses POSIX process groups; this is
  Linux lifecycle evidence, not a claim of native Windows benchmark support.
- Matched interrupted-start control with the exact Windows-base helper and
  candidate helper under WSL: both propagate `KeyboardInterrupt`; the base
  leaves its real `sleep` child alive, while the candidate has already reaped
  it. The control explicitly cleans up both test-owned processes
  (`startup-control.py`, `base-servers.py`, `startup-control.txt`).
- Inventory before and after merging, including `-Candidate HEAD`: pass.
  `diff-guard.ps1`: pass, with 72 changed upstream files, unchanged by this
  import (`inventory.md`, `candidate-inventory.md`).
- `check-docs.py`, `check-dependencies.py`, `git diff --check`, and the
  imported-commit ancestry check: pass. No C++ edits require formatting.
- Hosted Linux/Nix and Windows CPU gates run on the draft sync PR; their
  results qualify that PR's exact head.

### Live checks and limits

No inference or shared runtime paths changed, so no GPU/model rebuild,
numerical sweep or inference timing comparison is required for this import.
The existing Windows qualification limits remain unchanged. The benchmark
cleanup result is supported by a real child process, without loading a model.
Preserve official ancestry by merging the sync PR with a merge commit.

## October 21, 2026

Status: **local handoff complete; #699 reverted; qualification limited below**
on `t3/sync-upstream-oct-21-prs`. The candidate is retained locally for review.
The maintained `windows-main` remains at the recorded base; it has not been
promoted past the outstanding qualification limits.

- Windows base: `db4f6fbcea0514db1456abf8571f20cb525de30e` (also
  `origin/windows-main` at fetch time; no unpublished divergence).
- Previous official ancestor: `f020bd3a`.
- Imported official head: `e060aeed923730b74ea3f4116c3c39de55741370`.
- Integration: ordinary merge of the recorded official head,
  merge commit `54fb4b4e`, followed by the explicit #699 revert `161035d8`.

| PR | Upstream change | Merge SHA |
| --- | --- | --- |
| [#692](https://github.com/gufo-org/gufo/pull/692) | Compare the bound publication waiter with cold by answer | `0e4f987b8145bc37fca25b601881abd369982c36` |
| [#540](https://github.com/gufo-org/gufo/pull/540) | Qwen 27B AR and DFlash2 cache continuation | `da5d5a2b237c654bc0523e33fdee10465240da0c` |
| [#690](https://github.com/gufo-org/gufo/pull/690) | Wide Flash-Next routes for prefill passes above eight rows | `53f73b5653b32caf1d8cb3113c3f2f05f0e88d0a` |
| [#699](https://github.com/gufo-org/gufo/pull/699) | Reduce Flash-Next sampled decoding overhead; **reverted/deferred on Windows** | `e060aeed923730b74ea3f4116c3c39de55741370` |

The only additional incoming commit is upstream's v0.20.0 release
`0c03748a`. Its version, manifest and changelog changes are retained as published.
No version is manually assigned by this sync.

### Merge review

Only `docs/models/qwen3.8-flash-next/EXPERIMENTS.md` and `QUALITY.md`
conflicted: both branches inserted independent evidence at the top. Retained
the October 21 upstream sections and the October 20 Windows n-gram evidence.
No source file required conflict resolution. The later #699 revert conflicts
only in `QUALITY.md`; its resolution removes the reverted claims and preserves
the Windows October 20 n-gram evidence.

Reviewed the clean merges in `inference_backend.cpp`,
`text_model_runner.cpp`, `text_generation_scheduler.cpp` and the Flash-Next
ROCm executor: WDDM-aware resource claims, native host-memory accounting,
live prefill metrics and snapshot admission remain present. Shared snapshot
copy kernels moved to `src/core/hip/snapshot_copy.*`; their consumers and
both model build lists follow the move. Windows disk-store guards remain.

The shared transfer pool now supports a bound execution stream. Native pinned
transfer coverage additionally checks real copies on that stream, invalid and
repeated binding, and stream-owner retention after pool/lease destruction until
the completion releases it. Linux fault-injection harnesses remain unchanged.
The initial import's native run also exposed a stale pre-sync fixture: committed backing
now registers anonymous pages, but the test still queried `hipHostMalloc`
flags. It now checks the host registration and device mapping; staging still
checks `hipHostMallocCoherent`. The allocator is unchanged by this sync.
See [AMD's memory API contract](https://rocm.docs.amd.com/projects/HIP/en/latest/doxygen/html/group___memory.html).

### Compatibility and validation

Validation results and pending qualifications are recorded here before handoff.
Its `build/sync-2026-10-21/` evidence was not archived and is no longer retained.
The previous Windows executable and colocated DLLs remain in the maintained
checkout; the candidate builds into this task's own `build/` directories.

| Contract | Outcome |
| --- | --- |
| Cached concurrent n-gram reads | Native independent row/hash/offset/descriptor checks pass. Windows still uses `O_CONCURRENT_RANDOM`; fresh-process AR/MTP controls below. |
| WDDM admission budgets | Validated: native live DXGI/HIP oracle and allocation/fallback checks pass. Existing admission helpers survive the merge. Multi-GPU switching remains unqualified. |
| Pinned memory and transfer lifetime | Validated: corrected/expanded native test passes, including bound-stream copies/ownership. Flash-Next AR/MTP 4K cross-slot probes reproduce every captured component, logits, next-step tokens and actual MTP drafts. Fault injection and physical memory pressure remain unqualified. |
| Sockets and shutdown | Implementation unchanged; all bounded CPU transport and real console-shutdown checks pass. |
| Filesystem identity, privacy and failures | Implementation and both checkpoint-store guards unchanged; bounded CPU identity/privacy/failure checks pass. Disk persistence remains deferred. |
| GPU queue policy | Windows boundary unchanged; CPU and HIP startup checks pass. No Windows queue-residency/performance claim. |

Completed checks (TheRock 10.0.0/Clang 23.0.0, MSVC 14.51.36231,
SDK 10.0.26100.0, CMake 4.4.0; compiler/cache details in the retained logs):

- `tools/windows/build.ps1 -Preset windows-cpu -Vcpkg VCPKG_PATH` and
  `ctest --preset windows-cpu --no-tests=error`: **15/15 pass** on the import (17.83 seconds) and again after the revert
  (16.91 seconds).
- `tools/windows/build.ps1 -Preset windows-gpu -Vcpkg VCPKG_PATH`: production
  HIP executable builds. Both builds use this checkout's pinned vcpkg manifest.
- Affected extra CPU checks: sampling, idle spill, Qwen continuation layout,
  Flash-Next n-gram, MTP sampling and prompt lookup: **6/6 pass**.
- Focused GPU gate: WDDM, pinned transfers, queue policy, speculative verifier,
  Qwen attention policy/long-context operators, Flash-Next projections,
  routed experts, snapshot copies and sampled-verification oracle: **10/10
  pass across the initial run and the focused pinned-fixture rerun**. The
  original failed pinned-fixture result is retained, not overwritten. After
  reverting #699, the remaining focused gate passes **9/9** (71.69 seconds);
  #699's removed sampled-verification test is not counted as a current pass.
- Qwen 27B continuation probe at 32K: **pass**, including component bytes,
  restoration and next-step logits/tokens. Native `--prefill-cancel-only` with
  the official DFlash2 sidecar: **AR and DFlash2 pass** exact resume against
  direct cold execution, with actual drafting. The broader
  `--continuation-only` includes Windows-disabled disk persistence and remains
  outside this qualification.
- Flash-Next continuation probe: `--mode ar` and `--mode mtp`, each with
  `--context 4096 --sessions 2 --backing-gib 1 --round-trip`: **pass**.
- Post-revert Flash-Next `qwen38_flash_next_session_test` with
  `--sampling-only` and `--cache-only`: **both pass**. Coverage includes graph
  capture/execution, EOS and sampling variants, 200-token checkpoint replay,
  and learned-policy greedy/thinking/nonthinking continuation with exact
  tokens, sampler state, drafts and final logits after RAM/serialized restores.
- Standard post-revert `gufo bench -p 2048 -n 128 -r 1 -v` with
  `--speculative off`, then `--speculative mtp --mtp-model MTP_PATH`:
  **both complete with exit zero**. AR pp/tg: **1,807.04/28.88 tok/s**;
  MTP pp/tg: **1,753.56/38.65 tok/s**. Greedy tg128 hashes match:
  `5177a75da6988d5ce9a14e1a744ed16829784eda18d40139d8a1e76469af8412`.
  MTP proposes 109 and accepts 58 drafts. These single-repetition spots do
  not qualify a branch speedup. Commands/results are retained in
  `final-bench-*-command.json`, logs and `final-bench-summary.json`.
  Windows PowerShell wraps verbose native stderr in `NativeCommandError`
  records; the captured benchmark exits are zero.
- Shared `tools/ci/check-format.py` with clang-format 21.1.8,
  `tools/ci/check-docs.py`, `tools/ci/check-dependencies.py`, and
  `git diff --check`: **pass**.
- Functional-runner unit tests under WSL: **80/80 pass**; new Qwen recovery
  evidence-refusal tests: **6/6 pass** on Windows and WSL. The initial Windows
  runner invocation hit a default-encoding failure (the affected case passes
  with Python UTF-8 enabled) and the existing POSIX-only `SIGHUP` harness.

The additional independent `qwen38_flash_next_gpu_probe --mtp-audit` fails
on image sequence 1, step 0: head-mixer relative RMS `0.0000695` exceeds the
unchanged `0.00005` scalar-oracle limit (maximum absolute error `0.0047131`).
The exact pre-sync Windows base, rebuilt with the same toolchain and the
byte-identical audit fixture, reproduces every printed value and failure.
This is an inherited Windows numerical qualification gap, not a new sync
failure. The oracle is not passed, its tolerance is unchanged, and both
`final-mtp-audit.log` and `baseline-mtp-audit.log` are retained.

Additional Windows harness exclusions, retained as failures in the evidence:
`cache_slot_test` requires POSIX `fork`/`SIGABRT`; `component_text_cache_test`
and `text_model_runner_test` reach the deliberately disabled disk stores.
These broader tests are outside the bounded Windows preset. They do not pass
on Windows and were not made to pass by weakening the store guards.

### Live checks and limits

The initial import's Flash-Next AR and MTP pass the SDK `long-context` and `cache-depth`
suites with 32K contexts, two sessions and an explicit 8 GiB RAM budget.
They exercise multi-turn recall, exact warm/cold answers, deep RAM reuse,
rewritten branches and peer rotation. MTP responses contain actual proposed
and accepted drafts. Each suite retains all request/phase timings; these
correctness runs do not by themselves qualify speed.

After the #699 revert, Qwen 27B AR and official DFlash2 also pass both API
suites at 32K/two sessions/8 GiB. DFlash2 responses contain actual drafts
(up to 115 proposed tokens in the long-context observations); both private
test servers exit cleanly with code zero. These runs exercise the #540
component-cache path rather than Windows-disabled disk persistence.

The additional `sampling-defaults` suite passes its explicit/default sampler
output checks but fails its zero-prefill replay assertion after the deep-cache
history: 15 of 22 prompt tokens are reused, and seven are re-prefilled.
Both exact pre-sync AR and MTP baselines reproduce the same output and
seven-token failure under the same deep history. Fresh MTP baseline and
import processes pass this suite. This is an inherited history-sensitive
cache assertion, not evidence of a new sampling regression; no blanket
sampling/cache or timing pass is claimed. The baseline MTP long-context
control also flags a reasoning-signature replay despite a correct answer;
the import passes that check. All raw observations remain retained.

The varied fresh-process prompt contains 11,036 tokens. Each process sends it
once with default prompt reuse and then with `cache_prompt: false`; both
requests report zero reused tokens. The initial AR prefill times are
6,533.72/6,093.59 ms (base) and 6,298.96/6,072.70 ms (initial import), with identical
completions and prompt/cache/draft counts. The repeated AR baseline also passes
the strict request-phase limits against that import. Its cumulative idle-copy
counter covers only 25.69 MiB at the second response, versus 72.48 MiB on the
import; the initial baseline covers 30.67 MiB. Those asynchronous background
totals are different work, remain visibly inconclusive in the raw comparison,
and do not qualify background-copy performance.

Controls use the exact Windows base built separately in the retained detached
`baseline-source` worktree, TheRock 10.0.0 for both revisions, byte-identical
runtime DLLs and one common `run-bin/gufo.exe` path. Builds finish before these
HTTP timing runs. Binary SHA-256 values, commands, loaded `/props`, complete
responses, phase counters, individual timings and graceful shutdown results
are in `identities.json` and the per-arm JSON/log files. Model identity uses
path/size/mtime; full model hashes were not collected. The initial import reports `db4f6fbcea05-dirty`; the final tested code is
commit `161035d8` (with documentation edits present during the build). Its
SHA-256 is `447196666e8f2e1158e78ac59ab2b464ee58469d2a84226ed1dec619e1419298`.
Both use upstream's 0.20.0 version; retained patches and binary hashes
distinguish every arm.

The rebuilt revert passes the affected MTP first-decode gate. Final AR
prefill measures 6,309.95/6,109.18 ms and decode 42.65/35.24 ms; these phases
also pass against the focused base control, with identical output and work.
Snapshot timing remains unqualified: final MTP first snapshot is 67.92 ms
versus 61.66 ms, and final AR snapshots are 53.51/40.56 ms versus 42.07/35.57 ms.
Those flags and asynchronous copy totals remain in
`reverted699-comparison.json` and `final-ar-comparison.json`; no complete
performance pass is claimed from these pairs.

Full Windows inference/performance qualification remains pending. Linux/Nix
checks could not run: WSL has Python but no Nix/CMake/compiler toolchain, and
no hosted check was triggered for this local-only handoff. Qwen Q8_K_XL and
the DSpark/DeepSeek profiles are unavailable locally and remain unqualified.
Multi-GPU, physical memory pressure and Windows disk persistence also remain
outside the evidence above. The upstream PRs' Linux measurements do not
qualify Windows. PR #699 is explicitly reverted for the Windows regression;
its prior Linux evidence does not override this disposition.
