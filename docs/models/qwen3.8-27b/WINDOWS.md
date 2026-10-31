# Qwen3.8 27B on Windows

Windows evidence belongs here. The upstream [benchmarks](BENCHMARKS.md),
[quality](QUALITY.md) and [experiments](EXPERIMENTS.md) describe Linux and remain
identical to official Gufo.

## Pinned prompt capture deferred (October 23, 2026)

Official #688 is in ancestry, but its pinned-capture optimization is explicitly
reverted after nine matched long-context timing cells fail on Windows/TheRock
10.0.0. The independent DFlash2 upload-failure draining fix and its unchanged
upstream lifetime test remain included. See the
[sync/deferral record](../../WINDOWS-UPSTREAM-SYNC.md#pr-688-windows-dflash2-continuation-latency)
for exact identities, per-phase ranges and reintroduction requirements.

The rejected full import passes native Q4_K_XL numerical prefill/captured-row
and exact AR/DFlash2 cancel/resume checks. Both HTTP modes individually pass
long-context, text/thinking/tool/image RAM replay and disk restart/spacing.
Actual DFlash2 drafts are recorded. These are correctness observations, not
a performance or complete cross-build continuation pass.

Two candidate runs and three baseline runs retain equal effective 4 GiB RAM,
staging/disk capacities, 32K context, two sessions, identical model paths and
all 143 runtime files. The fully cached sampled replay has identical output,
12,454 prompt tokens, seven completion tokens and 11/five proposed/accepted
drafts. Candidate wall time is 405.42-419.80 ms versus baseline 351.75-358.76 ms;
restore is 20.77-21.44 ms versus 15.27-16.61 ms. The 5%/3 ms gates are unchanged.

An image continuation compares unequal cancellation frontiers (273/278 cached
tokens) and produces different seeded reasoning. Matched-frontier image probes
produce exact output/work on both builds and reproduce both output variants on
baseline. The original full comparison stays failed. Native lifetime testing
confirms that failed uploads drain before caller data is reused, for both
pageable and pinned sources, and that context injection recovers.

Evidence is retained under `sync-688-2026-10-23/` in
the [evidence archive](../../WINDOWS-UPSTREAM-SYNC.md#evidence-archive).
Cold-prompt/benchmark and broader qualification of the rejected optimization
stopped after the deferral decision. No speedup or full Windows performance
pass is claimed.

## Retained upload cleanup (October 23, 2026)

The final subset is built clean at `852e2455`, production SHA-256
`c8e66f755e4af759be88500ea253cc2a532f740c3989131a41c1b23d52861740`.
Its only production change from the merged #77 base is the upload scope guard;
successful calls keep the previous wait. CPU 16/16, native upload failure and
recovery, numerical prefill/captured rows and exact AR/DFlash2 cancelled-prefill
resume pass. HTTP RAM replay at 8192 context/one slot/1 GiB reuses all 2,294
prompt tokens without prefill; both cold/retry outputs match and each proposes
18/accepts 17 drafts. The test-owned server shuts down cleanly.

Standard pp2048/tg128 spots complete on baseline and final subset in AR and
DFlash2, with one common executable path and identical output hashes in all
four runs. DFlash2 acceptance is 0.439 in both arms. Raw rates and complete
commands remain in `bench-*.log` and `bench-jobs.json`; single-repetition spots
do not establish a speedup or complete performance qualification.
