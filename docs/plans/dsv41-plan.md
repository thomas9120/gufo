# DeepSeek V4.1 Flash with SSD streaming

Status: planned, not started (2026-10-24). Nothing below is implemented.

## Objective

Run the ISTA-DASLab GSQ-RCO `IQ2_XXS` build of DeepSeek V4.1 Flash 1017 on a
128 GB Strix Halo (`gfx1151`), with the Engram tables and the routed experts
that do not fit in memory streamed from a local NVMe SSD. Text generation only.
Write the code so official Gufo can take it: model-private package, Linux and
Windows I/O behind one interface, and no Windows-only assumptions in the graph.

Only this exact artifact is supported. Other V4.1 builds (antirez's ds4-native
Q2/Q4/MXFP4 GGUFs, the ISTA `IQ1_M`/`IQ2_XS` builds, other converters) are out
of scope. The loader refuses anything else by identity rather than by a
best-effort compatibility check.

## Target artifacts

Source: [ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF](https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF).
Local copy: `C:\Users\pegas\Documents\Llama\LLama-GUI\models\ISTA-DASLab_DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF`.

| File | Bytes | Role |
| --- | ---: | --- |
| `DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS-00001-of-00004.gguf` | 39,075,714,624 | Backbone shard 1: metadata, tokenizer, chat template, Engram hash tensors, experts for layers 0–12 |
| `…-00002-of-00004.gguf` | 39,388,449,504 | Experts, layers 12–24 |
| `…-00003-of-00004.gguf` | 39,246,891,616 | Experts, layers 24–35 |
| `…-00004-of-00004.gguf` | 20,527,837,312 | Experts for layers 36–39, plus all dense tensors |
| `DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf` | 110,595,290,816 | The two Engram tables (`deepseek41-engram`), found from `deepseek41.engram.file` |
| `dspark-DeepSeek-V4.1-Flash-1017-Q8_0.gguf` | 7,976,914,240 | Optional DSpark drafter (`dflash` architecture), phase 7 |
| `mmproj-BF16.gguf` | 972,208,288 | Vision projector; out of scope |

Phase 1 pins SHA-256 hashes and the HF revision in
`docs/models/deepseek-v4.1-flash/artifacts/model-identities.json`.

### Measured layout

Read from the GGUF headers on 2026-10-24:

| Part | Size | Placement |
| --- | ---: | --- |
| Dense weights (attention, shared experts, router, HC, indexer, compressor, embeddings, output, Engram projections) | 6.16 GB | Always resident in VRAM |
| Routed experts: 40 layers × 384 experts × gate/up/down | 132.07 GB | Bounded VRAM cache backed by the SSD |
| Engram tables: layers 1 and 14, ~384M rows × 256 dims each, `IQ4_NL` (144 B per row) | 110.60 GB | Always on disk; rows read per token |

Notes on the layout:

- **Expert types vary per tensor.** Each routed tensor is `IQ1_M`, `IQ2_XXS` or `IQ2_XS`, chosen per tensor by the RCO search. One expert's gate+up+down takes 7.4 MiB (`IQ1_M`), 8.7 MiB (`IQ2_XXS`) or 9.75 MiB (`IQ2_XS`). The dense tensors are `Q5_K`, `Q8_0`, `BF16` and `F32`.
- **Expert slices are not 4 KiB-aligned** in the file, so unbuffered reads must over-read, or use a repacked file (see [expert pack](#expert-pack-optional)).
- **Engram per token:** each Engram layer reads 24 rows (inferred as 8 heads × n-gram orders 2–4). That fits `engram_primes` `[24, 2]` and the 6144 = 24 × 256 input width of `engram_wkv`. It totals 48 rows of 144 B per token. The row indices depend only on token IDs.

## Hardware budget

The host is a Ryzen AI Max+ 395 with 128 GB, set to a 96 GB VRAM carve-out, so
Windows sees 32 GB as system RAM. The model is on `C:`, a Crucial P310 2 TB
(PCIe 4.0 NVMe, QLC, DRAM-less). The Samsung 970 EVO Plus is on USB and is not
a supported location.

| Use | Approximate budget |
| --- | ---: |
| Dense weights | 6.2 GB VRAM |
| KV, indexer state, scratch, HIP dispatch reserve | 4–8 GB VRAM, depending on context |
| DSpark drafter (when enabled) | 8 GB VRAM |
| Expert cache | The rest of VRAM: about 74–84 GB, or 56–64% of the experts |
| Pinned staging ring | 0.5–1 GB host memory |
| OS page cache (Engram rows, recently evicted experts) | Whatever remains of the 32 GB |

Rough performance expectations, to be replaced by phase 0 measurements:

- **Decode:** about 240 expert uses per token. At a 65–75% hit rate that misses about 0.5–0.8 GB per token. At 5–6 GB/s that is an I/O limit of about 6–10 tok/s; with compute, about 3–6 tok/s. Skewed routing, prefetch and DSpark improve this.
- **Prefill:** a wide chunk touches nearly every expert in each layer. Each chunk therefore streams about 50 GB of non-resident experts, about 9 s. A 4K-token chunk gives a few hundred tok/s.
- **Engram:** 48 random 4 KiB reads per decoded token, and up to ~200k per 4K prefill chunk before deduplication. This is small next to expert traffic.

## Architecture deltas from V4 Flash

The existing `src/models/deepseek_v4_flash` package (ported from antirez/ds4
`84cc8823`) is the starting point. Here is how V4.1 differs:

| Area | V4 Flash | V4.1 Flash (`deepseek41`) |
| --- | --- | --- |
| Shape | 43 layers, width 4096, 256 experts | 40 layers, width 5120, 384 experts, 6 active, expert FFN 2304 |
| Routing | Hash-routed early layers | `hash_layer_count = 0`; `sqrtsoftplus` scoring with `exp_probs_b` bias, weights normalised and scaled by 1.5 |
| SwiGLU clamp | Routed experts | Routed and shared experts, separate per-layer arrays |
| Attention KV | Per layer | Cross-layer sharing: `kv_source_layer_ids = [2, 8, 14, 20]` |
| Sparse indexer | Per layer | Shared: `index_source_layer_ids = [2, 8, 14, 20, 24, 28, 32, 36]` |
| Candidate blocks | — | Block size 8, top 2048 blocks, taken from layer 20 |
| Compressor | — | `compress_ratios` array (43 entries); compressor tensors on 4 layers; separate `compress_rope_freq_base` |
| Engram | — | Layers 1 and 14: hashed n-gram lookup, `engram_q`/`engram_k` gating into the four hyper-connection streams, `engram_wkv` projection |
| Tokenizer | DeepSeek V4 | `joyai-llm` pre-tokenizer, compressed Engram vocabulary of 99,092 tokens through `engram_token_map` |
| Chat | Effort low/high | Integer reasoning effort from 1 to 100, or low/high/max (50/75/100), rendered as a system prefix in thinking mode |
| Drafter | DSpark support GGUF | `dflash`: 3 blocks, 128 experts with 3 active, block size 5, uses target layers 37–39, has a confidence head |

These deltas need an oracle before any GPU work (phase 1).

## Design

### Package

Create a new package, `src/models/deepseek_v41_flash/`, starting as a copy of
the V4 package, with its own `UPSTREAM.md` naming the pinned ds4 commit it
imports from. Following the repository rule, it shares no mutable state or
kernels with V4 or Qwen. Tools live in `tools/ds41/` and tests sit next to the
model. The V4 package is not changed.

Implementation sources:

- **Graph, Engram and streaming:** antirez/ds4, pinned to a commit that has `ds4_engram.c`, `ds4_ssd.c` and `ds4_deepseek41_*`. It is MIT-licensed, like the existing import.
- **Tensor layout and hashing:** the llama.cpp `deepseek41` converter. The ISTA files use that layout, not ds4's single-file layout.
- **Numerical reference:** DeepSeek's official `inference/model.py`, through the llama.cpp port (see [phase 1](#phase-1-oracle-and-format-contract)).

### Streaming I/O layer

The I/O layer is a small interface owned by the model package and implemented
per platform. Only the implementations differ; the graph and cache code are
shared.

```
class BlockReader {
  // Queue reads of file ranges into caller-owned pinned buffers; completion
  // is reported through Poll/Wait. Offsets and lengths are arbitrary; the
  // implementation handles alignment.
  Submit(span<const ReadRequest>);
  Poll(); Wait(ticket);
};
```

- **Windows:**
  - Expert reads use `FILE_FLAG_NO_BUFFERING | FILE_FLAG_OVERLAPPED` and an I/O completion port with a few worker threads. Windows 11 IoRing is a later alternative, chosen by measurement.
  - Reads are widened to sector boundaries into aligned staging, and the caller gets the inner slice.
  - Engram reads use a separate buffered handle, so the OS page cache keeps hot rows.
  - The shared contracts in [WINDOWS-COMPATIBILITY.md](../WINDOWS-COMPATIBILITY.md) apply, including no file locks held across sessions and the existing mapped-file conventions.
- **Linux:** `O_DIRECT` with `io_uring`, or a `pread` thread pool. This is the path upstream would use.
- **Staging:** a ring of pinned host buffers, filled from disk and then copied to VRAM with `hipMemcpyAsync` on a dedicated copy stream. Phase 0 checks whether this copy is needed, or whether kernels can read pinned memory directly at full speed on gfx1151 under WDDM.

### Expert cache

- **Slots:**
  - Fixed-size VRAM slots, one size per quant type. Each slot holds one (layer, expert) gate+up+down triple.
  - The slot count follows from the budget above, computed at load from the WDDM budget (`fix(windows): use WDDM budgets for GPU memory admission`) after dense weights, session state and the drafter are reserved.
- **Indirection:**
  - A device table `slot_of[layer][expert]` is consulted by the MoE kernels in place of `base + expert * stride`. This is the only kernel-visible change to the MoE path.
  - A miss leaves an invalid entry, and the layer is not launched until its entries are valid.
- **Residency policy:**
  - At load, preload a frequency-ordered hot list. It is generated by a calibration tool from routing traces of a small corpus and stored as a model artifact.
  - At run time, evict by LFU with aging.
  - Pin the experts of the current layer and the next layer during a step.
- **Decode, one token:**
  1. Run the router.
  2. Copy the 6 selected expert IDs to the host. This is one small device-to-host sync per layer.
  3. Submit reads for the misses.
  4. Copy them into slots and update `slot_of`.
  5. Launch the MoE kernels.
  
  Overlap I/O with compute two ways:
  - Prefetch layer L+1 by running its router on layer L's hidden state (pre-gating). Measure its accuracy; if it is poor, drop it.
  - Start the shared expert and attention of layer L+1 while routed reads complete, wherever the data dependencies allow.
- **Prefill, one wide chunk:**
  - Compute the union of selected experts per layer.
  - Read the misses in file order with adjacent reads merged, double-buffered so layer L+1's reads overlap layer L's compute.
  - Use temporary slots that are not inserted into the decode cache unless they qualify under LFU.
  - Choose the chunk width so read time per layer is close to compute time.
- **Batching:** multi-session decode takes the union of selections across rows, as in the existing batched path. DSpark verification is the same case: each verify step is a small batch, so expert reads are shared across draft tokens.
- **HIP graphs:** if the V4 decode path uses graph capture, V4.1 runs per-layer segments split at the routing sync points.

### Engram

- Hash on the CPU when a token becomes known: prompt tokens at submission, the sampled token at once, draft tokens when proposed.
  - The hash maps tokens through `engram_token_map`, builds n-grams of orders 2–4 from the session's history and applies `engram_multipliers`, `engram_primes` and `engram_offsets`. The exact formula comes from the oracle (phase 1).
- Deduplicate row indices within a step, then issue buffered 4 KiB reads into a pinned row buffer.
- Layer 1's rows must be ready before layer 1 runs. Layer 14's rows have most of the step as slack.
- Dequantize `IQ4_NL` on the GPU inside the Engram gating kernel.
- **Session state:** the last three tokens (the n-gram history) are part of request state. RAM/disk continuation caches and snapshots must save and restore them, and cache keys must cover them. llama.cpp #30944 shows the failure when this is missed: a single corrupted token after reusing a prefix.

### Expert pack (optional)

`tools/ds41/pack_experts` writes a derived, rebuildable file. Each expert's
gate, up and down slices sit together, 4 KiB-aligned, in layer-major order,
plus an index that records source offsets and checksums. One aligned read per
miss then replaces three unaligned ones. It costs about 133 GB of disk (`C:`
has about 424 GB free). Adopt it only if phase 0 or phase 5 measurements show a
gain. The original shards remain the source of truth, and the loader verifies
the pack index against them.

## Phases

Each phase ends with a commit series and its own PR. Every phase has an exit
criterion; if the criterion fails, stop and decide whether to continue.

### Phase 0: I/O and runtime feasibility

Write a standalone `tools/ds41/io_probe` against the real shard files on
Windows. It measures:

- unbuffered overlapped reads of 7–10 MiB at queue depths 1, 4, 8 and 16, in random expert order and in file order;
- 4 KiB random reads of the Engram table at queue depths 1, 16 and 48, both buffered (cold and warm) and unbuffered;
- pinned host → VRAM copy throughput, and direct kernel reads from pinned memory;
- device-to-host sync latency for a tiny readback on a busy stream, through HIP on WDDM.

Exit: the measured numbers in a table in this file, and an updated
[performance estimate](#hardware-budget). Go if the I/O limit on decode is at
least 3 tok/s at a 65% hit rate.

### Phase 1: Oracle and format contract

- Build the llama.cpp `deepseek41` branch (PR #30817, or the branch it depends on) on Windows, CPU or Vulkan, with mmap. Confirm it loads these exact files.
- Capture reference outputs: tokenization of a fixed text set, the rendered chat template, Engram row indices for fixed token sequences, and full logits for several short prompts (≤ 64 tokens, both with and without thinking).
- Store small fixtures in the repository and large captures outside Git, following the existing DS4 practice.
- Write the format contract: tensor names, shapes, the per-tensor type table (from ISTA's `rco-allocation.txt`) and the Engram hash definition.
- Pin artifact hashes.

Exit: reference fixtures reproduce on a second run, and the hash definition is
written down with a CPU implementation in `tools/ds41/` that matches the
oracle's row indices exactly.

### Phase 2: Loader, tokenizer, chat

- Create the package. Load the four shards through the core split-GGUF reader and the Engram file through `deepseek41.engram.file`, refusing anything outside the pinned artifact identities.
- Add the `joyai-llm` pre-tokenizer, the chat template with integer reasoning effort, and DSML tool-call parsing.
- Register the model with the CLI and server. A clear "not yet runnable" error is acceptable here.

Exit: tokenizer and template fixtures match the oracle, and the loader reports
the measured layout above.

### Phase 3: Correct graph with naive streaming

Port the V4.1 graph from ds4 and adapt it to the ISTA layout:

- shared KV and indexer;
- candidate blocks;
- compressors;
- Engram gating;
- `sqrtsoftplus` routing;
- the shared-expert clamp;
- MoE paths for `IQ1_M` and `IQ2_XS` in addition to `IQ2_XXS`, using the vendored ggml `mmvq`/`mmq` kernels before any fused kernels;
- `Q5_K` dense projections.

Streaming in this phase is deliberately simple: a synchronous per-layer miss
read into the slot cache, without prefetch.

Exit: greedy tokens and full-logit error against the phase 1 oracle within the
agreed tolerance on all fixtures. Correctness is not established until this
passes. This is the riskiest phase.

### Phase 4: Expert cache and asynchronous I/O

Add the `BlockReader` implementations for Windows and Linux, the pinned
staging ring, LFU with the hot list, pre-gating prefetch, the wide prefill
strategy and multi-session unions. Add the routing-trace calibration tool that
generates the hot list.

Exit: outputs bit-identical to phase 3, and decode/prefill measured with the
standard benchmark workflow at several context depths, with hit rates
reported.

### Phase 5: Engram pipeline and session state

Add asynchronous Engram reads at token time, deduplication, n-gram history in
request state, snapshots and RAM/disk continuation caches, and cache-key
coverage.

Exit: the `cache` and `long-context` functional suites pass, including
prefix-reuse cases built to cross an n-gram boundary (the llama.cpp #30944
scenario), with outputs identical to a fresh run.

### Phase 6: Performance

Profile with `tools/prof/prof.py`. Then:

- add fused kernels for the dominant expert types where profiles justify them;
- decide on the expert pack and IoRing by measurement;
- tune chunk widths and the cache budget.

Follow `.agents/skills/optimize-kernel/SKILL.md`. Successful optimizations
become the default.

### Phase 7: DSpark drafter

Port the `dflash` drafter: 3 blocks, block size 5, target layers 37–39, and a
confidence head. It is resident in VRAM and reduces the expert-cache budget by
8 GB. Measure whether the gain from verifying several tokens at once beats
that smaller cache.

Exit: drafter acceptance, outputs matching AR as in the V4 DSpark checks, and
a net speedup. Otherwise ship without it.

### Phase 8: Documentation and upstream proposal

- Write `docs/models/deepseek-v4.1-flash/` (README, BENCHMARKS, QUALITY) in the existing model-doc format, with the streaming requirements: a local NVMe SSD and the free space needed.
- Write a Linux qualification note, and open an issue or discussion upstream before sending code.

## Testing

Run the smallest suites that cover each change, as `AGENTS.md` requires:

- **Unit tests (CPU):** Engram hashing, n-gram history across sessions, slot-table updates, cache eviction, `BlockReader` alignment arithmetic.
- **Kernel checks:** each expert quant type through the indirection table against a dequantized FP32 reference.
- **Model checks:** the phase 1 oracle fixtures (logits and greedy tokens), in AR and later in DSpark.
- **Functional:** `tests/functional/` text API suites. Include `cache` and `long-context` for anything that touches continuation or Engram state.
- **Benchmarks:** the standard speed benchmark at several depths, plus loading time and peak memory. Always report cache hit rate and SSD bytes per token with streaming numbers.

A missing model or missing SSD is a skip, not a pass.

## Risks

| Risk | Mitigation |
| --- | --- |
| No trustworthy oracle: the llama.cpp support is a draft PR, and the official reference cannot run at this size here | Use the llama.cpp port for short prompts, cross-check the Engram hash against ds4 and llama.cpp, compare per layer where possible |
| ISTA and ds4 layouts differ in more than names, for example the tensor transposition of `engram_wkv` or the Engram row order | Phase 1 format contract and per-op fixtures before porting |
| WDDM adds device-to-host sync latency, or blocks overlap between the copy and compute streams | Phase 0 measures this; fall back to whole-layer prefetch if per-layer sync is too slow |
| Sustained reads slow down on the QLC, DRAM-less drive, or with heat | Measure sustained runs of several minutes in phase 0; document drive requirements |
| A low hit rate, because routing is less skewed than hoped | Hot-list calibration; report the hit rate; DSpark amortisation |
| The 32 GB host side runs short (page cache, staging, Gufo process) | Keep staging bounded; send expert reads around the page cache |
| Upstream syncs touch the V4 package | V4.1 is a separate package; sync with the [batching procedure](../WINDOWS-UPSTREAM-SYNC.md#batching) |

## Out of scope

- Vision (`mmproj`)
- Other V4.1 quants or converters
- Tensor parallelism or multi-GPU
- Fully resident mode (it does not fit in 128 GB)
- Streaming for V4 Flash

## References

- [ISTA-DASLab model card](https://huggingface.co/ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF)
- [antirez/ds4](https://github.com/antirez/ds4) and its [SSD streaming](https://github.com/antirez/ds4/blob/main/docs/SSD_STREAMING.md), [Strix Halo](https://github.com/antirez/ds4/blob/main/docs/STRIX_HALO.md) and [models](https://github.com/antirez/ds4/blob/main/docs/MODELS.md) docs
- [llama.cpp PR #30817](https://github.com/ggml-org/llama.cpp/pull/30817) (`deepseek41`, draft) and issue #30944 (prefix reuse breaks the Engram history)
- [DwarfStar: why the Engram stays on SSD](https://dwarfstar.sh/blog/deepseek-v41-engram-ssd/)
- [Existing V4 Flash port notes](../../src/models/deepseek_v4_flash/UPSTREAM.md)
