# VIctory macOS — investigation findings

**Date:** 2026-11-27 (UTC)  
**Executable SHA-256:** `b99f876b74d4a77f03af5f878223b27bd647b5c35a79d5decd9f716504239e93`  
**Tested source revision:** `87917243b0560571e9ff8ab39479031cc5e4b70c` (`8791724`)  
**Observed log:** `/tmp/victory-warm.log`, approximately 23:30–23:31 UTC  
**Purpose:** Record the observed macOS/Rosetta run, correlate it with the implementation, and distinguish confirmed causes from open questions.

This is an investigation record, not a claim that the game is fully playable or that the current rendering path is stable.

## Executive summary

The run gets substantially into the game startup and world rendering. Victory creates and uses D3D12 host pipelines, translates shaders, processes DirectStorage reads, and submits GPU work. The supplied log also contains host mesh-pipeline creation and frame reports. The user-visible window remained black while game audio was audible.

The world-stage reports show a severe performance collapse: approximately **0.2 FPS** and then **0.1 FPS**, with frame times of **4.38 s** and **7.95 s**. Host preparation is dominated by title-memory copies and texture preparation. The two reports account for approximately **27.0 GB** and **28.1 GB** of title-memory copy traffic per reported frame, plus approximately **4.8 GB** and **7.4 GB** of texture-preparation traffic.

The strongest source-backed performance lead is already present in the startup output: **fault-based memory tracking was off**. Under Rosetta, that means title-memory copies are refreshed wholesale rather than using the normal changed-page tracking path. The source documents this fallback and warns that it can reach tens of gigabytes per world frame.

There are also shader-compatibility losses: some wave64 operations cannot be lowered safely onto a 32-lane host, and at least one mesh shader exceeded Metal's 32,768-byte output limit. These are separate from the memory-copy bottleneck.

A Rosetta synchronous-exception message occurred at the end of the capture. Its cause is **not established**. In particular, fault tracking was reported off in this run, so the guarded-page failure mode documented for tracking-enabled runs cannot simply be assumed to explain this exception.

## 1. Test identity and startup facts

The startup output identifies the executable as:

- **Game build:** Series 1.0.2.1
- **Executable hash:** `b99f876b74d4a77f03af5f878223b27bd647b5c35a79d5decd9f716504239e93`
- **Mapped image base:** `0x6fffed550000`
- **Preferred image base:** `0x140000000`
- **CLWB handling:** 8 loops were made NOPs.

The loader scanned the executable and found **1,234 instruction candidates** in executable sections:

| Instruction | Count |
|---|---:|
| `vpmaskmovd` | 789 |
| `vpmaskmovq` | 160 |
| `vmaskmovps` | 180 |
| `vmaskmovpd` | 1 |
| `vcvtps2ph` | 70 |
| `vextractf128` | 33 |
| `vextracti128` | 1 |
| **Total** | **1,234** |

This is a scan count, **not** a count of instructions that faulted or were patched. The startup excerpt does not show a subsequent `masked stores N patched to plain stores` line or a `wide stores` patch summary.

The scan is relevant because the loader has machinery to replace selected AVX stores with trampolines that perform equivalent plain stores. That machinery exists to let Rosetta resume writes that cross protected-page boundaries. It does not follow that all 1,234 matches are problematic during this run.

## 2. Fault-based title-memory tracking

Startup explicitly reported:

```text
fault tracking off (title memory copied whole;
VICTORY_FAULT_TRACKING=1 turns it on, which also patches the stores Rosetta cannot resume)
```

This is a confirmed setting for this run.

### Why it matters

Victory's normal tracking design tracks changed **64 KiB pages**. When a tracked page is first written, the page guard reports the change so host copies only need to refresh changed pages. This avoids repeatedly copying the full range of every title-memory shadow.

Under Rosetta, fault-based tracking is disabled by default because Rosetta has known limitations resuming certain x86 AVX stores after a synchronous page fault. The relevant implementation is in:

- `crates/victory-gpu/src/watch.rs` — `fault_tracking()`, `rosetta()`, and `stores_need_patching()`.
- `crates/victory-loader/src/masked.rs` — scanner, instruction decoder, and trampoline patcher for masked/vector stores.
- `apps/victory/src/run.rs` — startup reporting and selection of patches for the title image.

When tracking is off, the implementation falls back to copying title memory wholesale. The source comments document that this can cost tens of gigabytes per world frame; the loader's masked-store module documents a prior world-streaming case of roughly 129 GB per frame. That 129 GB is a source-documented prior observation, **not** a measurement from this particular capture.

### Correlation with this run

The warm log reports approximately:

- **27,018.7 MB** of title-memory copies in the frame report around frame 1611.
- **28,092.7 MB** in the report around frame 1612.

That is consistent with the wholesale-copy fallback being a major contributor to the observed CPU preparation cost. The log does not yet establish how much of the copied range is avoidable, how much comes from memory outside Victory's write-watched pools, or what the performance would be with tracking enabled.

The startup code supports the opt-in:

```bash
VICTORY_FAULT_TRACKING=1
```

When enabled under Rosetta, `stores_need_patching()` becomes true. For this exact Series 1.0.2.1 executable hash, `apps/victory/src/run.rs` also adds eight known RVAs for plain 256-bit vector stores to the automatic patch selection. The explicit `VICTORY_PATCH_MASKED` setting can override the automatic selection.

**This switch has not been validated in the captured run.** Do not interpret the existence of the switch as proof that enabling it will be stable on this machine. The source records earlier Rosetta failures, including cases involving wide stores, and the patch path should be tested with startup patch counts and a fresh log.

A further distinction: only the runtime's GPU memory pools, physical-page views, and placeholders participate in this page tracking design. Other memory ranges (including some C-heap memory) are still copied whole. Enabling tracking therefore does not promise zero whole-range copies.

## 3. GPU and frame-time measurements

The supplied warm log contains two particularly useful frame reports.

### Report around frame 1611 — 23:30:54 UTC

| Metric | Reported value |
|---|---:|
| FPS | 0.2 |
| Frame time | 4,375.4 ms |
| Preparing time | 3,794.5 ms |
| Title-memory copies | 4,263.7 ms / 27,018.7 MB |
| Texture preparation | 1,744.4 ms / 4,783.0 MB |
| Host GPU time | 433.9 ms |
| Copy-back | 57.9 ms / 15.7 MB |
| Draws per frame | 3,053 |
| Draws dropped without a host pipeline | 1,066 (0 being made) |
| Indirect draws | 10 |
| Root-view slots per frame | 1,011 |

Host resource counters at this point:

- 3,843 host textures, 3,118 MB in total; 2,373 MB used by lists.
- 51 title textures sharing one host texture, saving 60 MB.
- 24 texture heaps, 1,599 MB used and 11 MB free.
- 13 depth-twin copies per frame.

### Report around frame 1612 — 23:31:02 UTC

| Metric | Reported value |
|---|---:|
| FPS | 0.1 |
| Frame time | 7,950.8 ms |
| Preparing time | 7,462.1 ms |
| Title-memory copies | 6,521.7 ms / 28,092.7 MB |
| Texture preparation | 6,071.4 ms / 7,421.0 MB |
| Host GPU time | 409.8 ms |
| Copy-back | 71.4 ms / 15.3 MB |
| Draws per frame | 3,948 |
| Draws dropped without a host pipeline | 410 (0 being made) |
| Indirect draws | 21 |
| Root-view slots per frame | 1,299 |

Host resource counters at this point:

- 3,915 host textures, 3,157 MB in total; 2,413 MB used by lists.
- 25 texture heaps, 1,597 MB used and 81 MB free.
- 20 depth-twin copies per frame.

The preparation counters are per-frame averages over the reporting window. They are not unique allocations or a direct measurement of physical DRAM bandwidth. In particular, do not add every timing field together as though the categories were guaranteed to be disjoint.

The queue diagnostics report no fence waits at present in these samples and very little time in the pump outside host submissions. They do report title-submission work running for approximately **4,258.6 ms** and **7,911.7 ms** per report frame. The host GPU times are approximately 434 ms and 410 ms respectively. This points to substantial work in both preparation/submission and GPU execution, rather than a simple fence-wait stall.

DirectStorage continues to complete batches during the capture (examples include 254–495 requests per batch). This shows that streaming I/O is progressing; it does not prove that all world assets have finished loading.

## 4. Shader translation and compatibility

The session also produced shader diagnostics for wave64 operations on a host whose wave width is at most 32 lanes.

The important nuance is that Victory does **not** simply reject every wave64 shader. The implementation in `crates/victory-shader/src/emit/lower/halves.rs` represents one console wave64 as two host waves of 32 lanes. It can lower several operations by exchanging values between the halves through group-shared memory and barriers.

That exchange is only correct where the whole thread group can participate in the required synchronization. Operations that need cross-half information in divergent or otherwise unsafe control flow are refused. The source describes specific cases, including cross-half lane reads, lane masks, first-lane reads, reductions, and LDS sharing without a suitable group barrier.

Consequently, the relevant diagnosis is **specific wave64 shader operations remain unsupported in some control-flow/synchronization contexts**, not that wave64 as a whole is impossible on the host.

The pipeline log also reported a mesh-shader output of **34,816 bytes** against a Metal limit of **32,768 bytes**. This shader exceeds the limit by 2,048 bytes (6.25%). The implementation in `crates/victory-shader/src/emit/mesh_size.rs` calculates the Metal-aligned output layout, and `crates/victory-gpu/src/pipeline/host.rs` uses the result to refuse an over-limit mesh pipeline. Other mesh pipelines were successfully created in the same session; this is a per-pipeline limitation, not evidence that all mesh shaders fail.

These shader/pipeline refusals can remove individual draws or dispatches and contribute to missing visual output. They are separate issues from the wholesale title-memory copy cost.

## 5. Host-pipeline scheduling and dropped draws

Host pipelines are compiled asynchronously by worker threads. The source in `crates/victory-gpu/src/pipeline/schedule.rs` sets a default **500 ms graphics-pipeline wait budget per title frame** and a **10 s bounded compute-pipeline budget**. `crates/victory-gpu/src/pipeline/make.rs` documents that a draw/dispatch whose pipeline is not ready within its budget can be dropped; a pipeline that fails translation or host creation can also leave a draw without a host pipeline.

The warm log reports:

```text
host pipelines all made *made*=187 *loaded*=1475 *started_early*=1574
```

It later reports 1,066 and 410 draws per frame dropped without a host pipeline, with `0 being made` at the time of the respective reports.

The `0 being made` value means those missing pipelines were not counted as actively being built in those samples. It does **not** prove that every dropped draw was caused by a shader refusal: a pipeline can be missing for more than one reason. The relevant next diagnostic is to correlate dropped draws with translation refusals, host-pipeline refusal reasons, and pipeline-cache state.

## 6. Rosetta synchronous exception

At approximately 23:31:05 UTC the log ends with:

```text
rosetta error: unexpectedly need to EmulateForward on a synchronous exception
x86_rip=0x6fffed474b2f
arm_pc=0x7422909d34
```

The main GTA VI image was reported mapped at `0x6fffed550000`. The exception RIP is **0xDB4D1 below** that base, so this address is not inside the mapped main executable image. The supplied output does not identify which module owns that address.

This matters when triaging the exception:

- The source documents this exact Rosetta error as a known failure when fault-based page tracking asks Rosetta to resume certain AVX stores after a guarded-page fault.
- **Fault tracking was off in this run.** Therefore the specific Victory guarded-page tracking path was not enabled, and the capture does not establish it as the cause of this exception.
- The executable contains many candidate AVX/vector stores, but the scan count alone does not show that any particular instruction faulted.
- The exception appears near later pipeline activity in the log, but temporal proximity does not establish a GPU-pipeline cause.

The exception remains an open investigation item. It needs module/stack attribution (and ideally a complete crash or diagnostic report) before assigning it to GTA VI code, Wine, Rosetta, or Victory.

## 7. Current interpretation

### Confirmed

1. The tested title is GTA VI Series 1.0.2.1 with the hash recorded above.
2. Victory detects 1,234 masked/vector store candidates in the executable.
3. Fault-based title-memory tracking was off in this run.
4. The world-stage reports show multi-second frames, tens of gigabytes of title-memory copy traffic, and substantial texture-preparation work.
5. Some wave64 operations are refused where the two-half lowering cannot safely synchronize.
6. At least one mesh shader exceeded Metal's 32 KiB mesh-output limit.
7. Many draws were reported without host pipelines; the sampled reports showed zero such pipelines actively being made.
8. A Rosetta synchronous exception occurred, but its owning module and cause are not identified by the supplied lines.

### Strong performance lead

The wholesale title-memory-copy fallback is the most concrete explanation for the unusually large copy volume and multi-second CPU preparation. Restoring changed-page tracking safely is the highest-value performance experiment because it targets a measured cost and has an existing opt-in/patching path in the code.

### Still unproven

- Whether enabling fault tracking with the built-in Series 1.0.2.1 patches is stable on this macOS/Rosetta setup.
- How much of the current copy volume is avoidable versus memory that cannot be page-tracked.
- Which exact shader hashes account for the largest visually significant missing passes.
- Whether the black window is primarily due to dropped/refused pipelines, a later rendering/presentation problem, or more than one issue.
- Which module and instruction caused the final Rosetta exception.

## 8. Recommended next experiments

1. **Preserve the current run as the baseline.** Keep the full log and record the environment switches used by the launcher. Do not compare runs if the shader cache, game build, output size, or launch options changed unnoticed.
2. **Run one controlled fault-tracking test.** Use `VICTORY_FAULT_TRACKING=1` only as an explicit experiment. Confirm startup says tracking is on and record the masked-store patch count (and the Series 1.0.2.1 wide-store patch result). Stop the experiment immediately if Rosetta hangs or emits the synchronous-exception error. Compare title-memory copy MB/ms, texture-preparation MB/ms, FPS, and stability against this baseline.
3. **Attribute the Rosetta RIP.** Capture the loaded-module map or a diagnostic stack at the exception and determine which image contains `0x6fffed474b2f`. Do not assume it is the main game executable.
4. **Separate shader losses by hash and refusal reason.** Group wave64-lowering refusals, mesh-output-limit refusals, translation failures, host-pipeline creation refusals, and compilation timeouts. This will distinguish correctness gaps from scheduling/cache misses.
5. **Re-test the visual result after the above are isolated.** Record whether the window remains black, whether audio continues, and whether a frame/present counter advances.

## Source locations

The following implementation files explain the mechanisms discussed above:

- [`apps/victory/src/run.rs`](apps/victory/src/run.rs) — build identification, masked-store scan, fault-tracking report, automatic Series 1.0.2.1 patch RVAs, CLWB handling.
- [`crates/victory-gpu/src/watch.rs`](crates/victory-gpu/src/watch.rs) — Rosetta detection, fault-tracking default, guarded-page write tracking.
- [`crates/victory-loader/src/masked.rs`](crates/victory-loader/src/masked.rs) — AVX/vector store scanning and trampoline patching.
- [`crates/victory-gpu/src/memory.rs`](crates/victory-gpu/src/memory.rs) and [`crates/victory-gpu/src/host.rs`](crates/victory-gpu/src/host.rs) — title-memory shadows, refresh/copy preparation, and per-frame reporting.
- [`crates/victory-shader/src/emit/lower/halves.rs`](crates/victory-shader/src/emit/lower/halves.rs) — wave64-on-wave32 lowering and cross-half refusal conditions.
- [`crates/victory-shader/src/emit/mesh_size.rs`](crates/victory-shader/src/emit/mesh_size.rs) and [`crates/victory-gpu/src/pipeline/host.rs`](crates/victory-gpu/src/pipeline/host.rs) — Metal mesh-output sizing and over-limit rejection.
- [`crates/victory-gpu/src/pipeline/schedule.rs`](crates/victory-gpu/src/pipeline/schedule.rs) and [`crates/victory-gpu/src/pipeline/make.rs`](crates/victory-gpu/src/pipeline/make.rs) — asynchronous host-pipeline workers, wait budgets, and dropped draws.

---

**Revision note:** The tested local revision was `8791724`. The repository's `main` branch subsequently advanced to `648d0851` with two commits affecting only `Launch.sh`; the source files used for this analysis were unchanged in that comparison. This document is being added to the current `main` branch.
