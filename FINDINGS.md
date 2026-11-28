# VIctory macOS — investigation findings

**Baseline date:** 2026-11-27 (UTC); **Rosetta follow-up:** 2026-11-28 00:10–00:16 UTC  
**Wide-store-list follow-up:** 2026-11-28 (after the 00:26 UTC exception)  
**Executable SHA-256:** `b99f876b74d4a77f03af5f878223b27bd647b5c35a79d5decd9f716504239e93`  
**Tested source revision:** `87917243b0560571e9ff8ab39479031cc5e4b70c` (`8791724`)  
**Baseline log:** `/tmp/victory-warm.log`, approximately 23:30–23:31 UTC  
**Follow-up logs:** `/tmp/victory-tracking.log` and `/tmp/victory-rva-test.log` (the latter supplied only in part)  
**Purpose:** Record the observed macOS/Rosetta run, correlate it with the implementation, and distinguish confirmed causes from open questions.

INVESTIGATION RECORD:  Apple M5 Air 2026 | 24GB unified RAM 

## Executive summary

The run gets substantially into the game startup and world rendering. Victory creates and uses D3D12 host pipelines, translates shaders, processes DirectStorage reads, and submits GPU work. The supplied log also contains host mesh-pipeline creation and frame reports. The user-visible window remained black while game audio was audible.

The world-stage reports show a severe performance collapse: approximately **0.2 FPS** and then **0.1 FPS**, with frame times of **4.38 s** and **7.95 s**. Host preparation is dominated by title-memory copies and texture preparation. The two reports account for approximately **27.0 GB** and **28.1 GB** of title-memory copy traffic per reported frame, plus approximately **4.8 GB** and **7.4 GB** of texture-preparation traffic.

The strongest source-backed performance lead is already present in the startup output: **fault-based memory tracking was off**. Under Rosetta, that means title-memory copies are refreshed wholesale rather than using the normal changed-page tracking path. The source documents this fallback and warns that it can reach tens of gigabytes per world frame.

There are also shader-compatibility losses: some wave64 operations cannot be lowered safely onto a 32-lane host, and at least one mesh shader exceeded Metal's 32,768-byte output limit. These are separate from the memory-copy bottleneck.

A Rosetta synchronous-exception message occurred at the end of the baseline capture. Its cause was **not established** at that stage. In particular, fault tracking was off in that baseline, so the guarded-page failure mode documented for tracking-enabled runs could not explain that exception without further evidence.

A follow-up run on 2026-11-28 enabled fault tracking under Rosetta. Startup confirmed tracking was on and reported **1,242 stores patched** for the Series 1.0.2.1 image. Rosetta then faulted inside the main image at RVA **0x22F7E6**, on a sequence of unaligned 256-bit `vmovups` stores. A subsequent run was launched with that site and the next store site added to the explicit patch list; its next reported exception was at RVA **0x22F7F4**, 14 bytes later, on a third `vmovups` store. The follow-up's final startup patch count has not yet been supplied, so application of both additional patches remains to be verified.

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

**The 2026-11-27 baseline did not validate this switch.** A 2026-11-28 follow-up did enable it and startup confirmed `fault tracking on`, but that run subsequently hit a Rosetta exception at a plain 256-bit store. This does not establish that the tracking-enabled configuration is stable on this machine. The source records earlier Rosetta failures involving wide stores, so each patch experiment must be checked against the startup patch count and a fresh log.

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

The main executable image was reported mapped at `0x6fffed550000`. The exception RIP is **0xDB4D1 below** that base, so this address is not inside the mapped main executable image. The supplied output does not identify which module owns that address.

This matters when triaging the exception:

- The source documents this exact Rosetta error as a known failure when fault-based page tracking asks Rosetta to resume certain AVX stores after a guarded-page fault.
- **Fault tracking was off in this run.** Therefore the specific Victory guarded-page tracking path was not enabled, and the capture does not establish it as the cause of this exception.
- The executable contains many candidate AVX/vector stores, but the scan count alone does not show that any particular instruction faulted.
- The exception appears near later pipeline activity in the log, but temporal proximity does not establish a GPU-pipeline cause.

The exception remains an open investigation item. It needs module/stack attribution (and ideally a complete crash or diagnostic report) before assigning it to the game, Wine, Rosetta, or Victory.

### 6.1. Tracking-enabled follow-up — 2026-11-28 00:10–00:16 UTC

The follow-up used the same Series 1.0.2.1 executable hash:

- **Executable SHA-256:** `b99f876b74d4a77f03af5f878223b27bd647b5c35a79d5decd9f716504239e93`
- **Mapped image base:** `0x6fffed550000`
- **Fault tracking:** explicitly reported `on`
- **Masked/vector-store scan:** 1,234 candidates (789 `vpmaskmovd`, 160 `vpmaskmovq`, 180 `vmaskmovps`, 1 `vmaskmovpd`, 70 `vcvtps2ph`, 33 `vextractf128`, 1 `vextracti128`)
- **First tracking-enabled patch count:** `1242 patched to plain stores`

The 1,242 count is the observed loader output for the first tracking-enabled attempt. It is consistent with all 1,234 scanned sites plus the eight Series 1.0.2.1-specific wide-store RVAs selected automatically by `apps/victory/src/run.rs`.

#### First tracking-enabled exception

The first reported exception was:

```text
rosetta error: unexpectedly need to EmulateForward on a synchronous exception
x86_rip=0x6fffed77f7e6
x86 instruction bytes:
  0xc4602444117cc1c4 0xc1c4402444117cc1
```

Subtracting the mapped image base gives:

```text
0x6fffed77f7e6 - 0x6fffed550000 = 0x22f7e6
```

The little-endian instruction bytes begin with two consecutive seven-byte AVX stores:

```asm
; RVA 0x22f7e6
vmovups [r12+0x60], ymm0

; RVA 0x22f7ed
vmovups [r12+0x40], ymm0
```

These are plain, unaligned 256-bit stores. They are not included in the masked-store byte scan; `masked.rs` only tries to decode plain wide moves when their RVAs are explicitly supplied. The source documents that a 256-bit `vmovups` crossing from a writable page into a protected page can make Rosetta emit this synchronous-exception error.

#### Second tracking-enabled exception

A repeat command was provided with `0x22f7e6` and `0x22f7ed` added to the explicit `VICTORY_PATCH_MASKED` list, retaining `all` and the eight existing build-specific RVAs. The zsh job-termination line displayed `VICTORY_PATCH_MASKED=` with no visible value, but the subsequent startup summary confirms that the two additional RVAs were in fact included: it reported `1244 patched to plain stores`. The next supplied exception was:

```text
rosetta error: unexpectedly need to EmulateForward on a synchronous exception
x86_rip=0x6fffed77f7f4
arm_pc=0x20552cc50
num_insts=3
inst_index=2
x86 instruction bytes:
  0xe9782444117cc1c4 0x48df894900000117
```

Using the same image base:

```text
0x6fffed77f7f4 - 0x6fffed550000 = 0x22f7f4
```

The bytes at the reported RIP decode to:

```asm
; RVA 0x22f7f4
vmovups [r12+0x78], ymm0
```

The new RIP is **14 bytes** after the first one. The observed addresses form a contiguous sequence of three seven-byte `vmovups` stores at RVAs `0x22f7e6`, `0x22f7ed`, and `0x22f7f4`. This spatial sequence is confirmed by the instruction bytes. It does **not** prove that execution moved past the first two stores in the same run, because the second run's explicit patch setting and startup patch count have not been verified.

The user subsequently supplied the second attempt's startup summary: `fault tracking on`, mapped base `0x6fffed550000`, and `masked stores 1244 patched to plain stores`. This confirms the two explicitly named RVAs `0x22f7e6` and `0x22f7ed` were included in the patch set: 1,234 scanned stores + eight existing Series 1.0.2.1-specific wide-store RVAs + two additional named wide-store RVAs = **1,244**. The shell job line's apparently empty environment display was therefore misleading/incomplete; the loader's startup count is the authoritative confirmation. Adding `0x22f7f4` as another unique site makes the expected count **1,245**, assuming it decodes and patches successfully.

The pipeline translation and host mesh-pipeline messages immediately after the second exception show that the log contains continuing worker activity around the failure. Their temporal proximity does not establish that mesh-pipeline creation caused the Rosetta exception.

#### Interpretation

- Fault tracking is now confirmed **on** in a tracking-enabled run, unlike the 2026-11-27 baseline.
- The first new fault RIP is inside the mapped main executable image, at RVA `0x22f7e6`; it is not the previously observed baseline RIP below the main image base.
- The failing instruction class matches the documented Rosetta limitation for unaligned 256-bit stores crossing a protected-page boundary.
- The second observed RIP identifies another store at RVA `0x22f7f4` in the same contiguous instruction sequence.
- The second run's startup count of 1,244 confirms that both additional sites, `0x22f7e6` and `0x22f7ed`, were included in the patch set.
- No evidence yet establishes that this sequence contains only these three stores, or that patching this sequence will eliminate all Rosetta exceptions.

#### Immediate follow-up

1. Read the startup portion of `/tmp/victory-rva-test.log` and retain the lines for `fault tracking`, `mapped at`, `masked stores N patched to plain stores`, and any `not a masked store or a plain 256-bit store` warnings. Confirm whether the second run reports **1,244**.
2. If the two earlier RVAs were confirmed patched, add `22f7f4` to the same explicit list for the next controlled run; the expected patch count then becomes **1,245**.
3. Preserve each complete log separately. Do not replace the automatic eight-RVA list when setting `VICTORY_PATCH_MASKED`: an explicit value overrides the automatic selection, so it must continue to include `all` and all eight existing RVAs.
4. If another store in this sequence faults, capture its RIP and bytes before adding further sites. Once the sequence is mapped, consider generating a complete wide-store site list for the relevant image rather than chasing one exception at a time.

### 6.2. Next Rosetta exception — 2026-11-28

A subsequent tracking-enabled run ended with:

```text
rosetta error: unexpectedly need to EmulateForward on a synchronous exception
x86_rip=0x6fffee32821a
arm_pc=0x2054bc008
num_insts=3
inst_index=2
x86 instruction bytes:
  0x3208011fcc5 0x3408011fcc5
```

The two 64-bit words are little-endian instruction bytes. They decode as two consecutive 8-byte VEX-encoded 256-bit `vmovups` stores:

```asm
; first instruction, at x86_rip
vmovups [rax+0x320], ymm0

; second instruction, eight bytes later
vmovups [rax+0x340], ymm0
```

The second store therefore begins at `x86_rip + 8`. Its encoded disp32 is `0x340` (not `0x334`); the first store's disp32 is `0x320`.

The last confirmed main-image base was `0x6fffed550000`. **If the current run reports the same base**, the arithmetic is:

```text
0x6fffee32821a - 0x6fffed550000 = 0x00dd821a
```

That is a provisional main-image RVA of `0xDD821A`; the second store is at `0xDD8222`. The offset is about 13.85 MiB from the image base, well within the approximately 114 MB executable file-size envelope recorded by the loader. This address is therefore not, by itself, evidence of a fault in a title DLL.

**Correction to the earlier conversational diagnosis:** the statement that `0x6fffee32821a` was above the main executable's mapped range was based on an incorrect subtraction. The correct difference from `0x6fffed550000` is `0xDD821A`, not `0x8DD821A`. Confirm the `mapped at` line from this same run before relying on the provisional RVA, because the base must come from the process that produced the exception.

The user subsequently supplied the startup excerpt from `/tmp/victory-rva-test-2.log`. It confirms `fault tracking on`, mapped base `0x6fffed550000`, and `masked stores 1245 patched to plain stores`. This verifies the three earlier extra sites (`0x22f7e6`, `0x22f7ed`, `0x22f7f4`) were included in the patch set. With this confirmed base, the current exception is inside the main executable image at RVA **`0xDD821A`**; the second store is at **`0xDD8222`**. Adding both to the same explicit `VICTORY_PATCH_MASKED` list should produce **1,247 patched stores**, assuming both decode and patch successfully.

This instruction sequence is consistent with another pair of unaligned 256-bit stores that Rosetta may be unable to resume when they fault across protected pages. The log alone does not establish that either instruction actually crossed a protected-page boundary; the next patch run is a controlled test of that hypothesis.

#### Immediate follow-up

1. The latest startup output is now confirmed: `fault tracking on`, mapped base `0x6fffed550000`, and **1,245 patched stores**. This includes the three previously identified extra sites.
2. Add RVAs `dd821a` and `dd8222` to the explicit `VICTORY_PATCH_MASKED` list, retaining `all`, the eight original build-specific RVAs, and the three previously identified sites. The expected count is **1,247**.
3. Preserve the full next log and check the startup patch count and any patch warnings before interpreting the next exception.

### 6.3. Further Rosetta exception — 2026-11-28 00:26 UTC

A subsequent run ended with:

```text
rosetta error: unexpectedly need to EmulateForward on a synchronous exception
x86_rip=0x6ffff2498e54
arm_pc=0x2077b9d58
num_insts=3
inst_index=2
x86 instruction bytes:
  0xc4f089482611fcc5 0x15f5c501d3186de3
```

Interpreting the supplied 64-bit words as little-endian instruction bytes, the bytes at the reported RIP begin:

```text
c5 fc 11 26 48 89 f0 c4 e3 6d 18 d3 01 c5 f5 15 ...
```

The instruction at the reported RIP is a **four-byte** VEX-encoded 256-bit unaligned store:

```asm
vmovups [rsi], ymm4
```

The following bytes begin other instructions (`mov rax, rsi` and a VEX-encoded instruction); they are not a second adjacent `vmovups` store.

The latest startup excerpt, supplied after the exception, confirms:

- Fault tracking: `on`
- Main image base: `0x6fffed550000`
- Masked/vector stores patched by `VICTORY_PATCH_MASKED`: **1,247**

The candidate main-image-relative offset is therefore:

```text
0x6ffff2498e54 - 0x6fffed550000 = 0x04f48e54
```

This gives a candidate RVA of **`0x4F48E54`**, provided the reported instruction address belongs to the mapped main image's executable section. The startup excerpt confirms the image base, but the actual bytes and section membership at this RVA still need to be verified against the cached mapped image.

#### Why the existing individual-RVA patcher is not sufficient

`crates/victory-loader/src/masked.rs` explicitly rejects plain 256-bit stores shorter than five bytes in `decode_wide_move`: the normal patch is a five-byte relative jump, and a four-byte instruction does not have room for it. Adding RVA `4f48e54` to `VICTORY_PATCH_MASKED` alone will not patch this instruction.

The repository provides a separate mechanism for this exact case:

- `cargo xtask wide-stores <cached title image> > wide-sites.txt` uses `llvm-objdump` to enumerate the title image's 256-bit stores.
- For a four-byte store, the generator can include adjacent movable instructions in a patch site, provided no branch target or unsafe instruction prevents it.
- `VICTORY_PATCH_WIDE=<file>` applies the generated site list by rewriting the 256-bit stores as two 128-bit halves.

The source comments identify the cached mapped executable under `<cache_dir>/images/`, but its filename is **not** based on the logged SHA-256 hash. `crates/victory-loader/src/prepare.rs`, `PreparedImage::file_name()`, names it `victory-image-<first-16-hex-of-BLAKE3(original executable bytes)>.dll`. The `victory config` command prints `cache_dir`, so the local cache path can be resolved without printing or transmitting the game installation path. Locate the large `victory-image-*.dll` candidate(s) rather than constructing the filename from the SHA-256 value.

#### Immediate follow-up

1. **Completed:** located the single large cached image in the checkout's active Wine prefix. The exact prefix, path, filename and size are recorded in §6.4.
2. **Completed:** generated `/tmp/victory-wide-sites.txt` with `cargo xtask wide-stores`; the file contains 117,413 newline-terminated entries. The generator's stderr summary was not retained in the supplied terminal output, so its total disassembled-store count and number of four-byte stores left unlisted are not yet recorded.
3. When using the complete generated list, set `VICTORY_PATCH_MASKED=all` for the scanned masked/vector stores and `VICTORY_PATCH_WIDE=/tmp/victory-wide-sites.txt` for the remaining unmasked 256-bit stores. Do not also keep the old manually named wide-store RVAs in `VICTORY_PATCH_MASKED`: the generated wide list includes those unmasked stores, and applying both patch mechanisms to overlapping sites can make the second patch reject already-modified bytes.
4. Confirm startup reports both `masked stores ... patched to plain stores` and `wide stores ... split into 128-bit halves`. Record the patched and refused counts; do not assume every site was patched.
5. Preserve the complete log and inspect the next Rosetta RIP if one occurs. A listed four-byte store may still be left unpatched if the generator cannot safely move enough adjacent instructions or a branch targets the candidate run.

The accompanying log lines showed host copies of title memory being released while memory was low, followed by completed DirectStorage read batches (including one batch of 1,309 requests). These establish memory-pressure handling and ongoing storage progress, but do not identify the cause of the Rosetta exception.


### 6.4. Cached-image discovery and wide-store list — 2026-11-28

The local search initially checked the conventional CrossOver bottles directory:

```text
~/Library/Application Support/CrossOver/Bottles
```

That directory contained neither a `victory-image-*.dll` file nor a directory matching `victory/cache`. This was a search-path mismatch, not evidence that VIctory had no image cache.

The macOS launcher in `tools/macos/victory.sh` sets its default Wine prefix to the checkout-local path `$ROOT/target/wineprefix-play` (unless `WINEPREFIX` is already set). The matching cache was found under:

```text
target/wineprefix-play/drive_c/users/crossover/AppData/Local/victory/cache/images/
```

Exactly one matching large image was reported:

- **File:** `victory-image-b99f876b74d4a77f.dll`
- **Size:** 120,181,760 bytes (approximately 114.6 MiB)
- **Search result:** one candidate matching `victory-image-*.dll` and larger than 80 MiB

The filename is the cache-generated name described in §6.3; it should not be reconstructed from the logged SHA-256.

The first `command -v llvm-objdump` check returned no path. After installing Homebrew LLVM and adding its `bin` directory to the command's `PATH`, the following generation command completed successfully:

```bash
PATH="$(brew --prefix llvm)/bin:$PATH" cargo xtask wide-stores \
  "$PWD/target/wineprefix-play/drive_c/users/crossover/AppData/Local/victory/cache/images/victory-image-b99f876b74d4a77f.dll" \
  > /tmp/victory-wide-sites.txt
```

The user supplied the command's success message and this line count:

```text
117413 /tmp/victory-wide-sites.txt
```

The resulting file therefore contains **117,413 list entries**. Per `xtask/src/wide_stores.rs`, each line describes a patch site using its RVA, overwritten byte count, and instruction pieces; it contains offsets and patch metadata, not game assets or the executable's contents. The generator disassembles the cached image's `.text` section, lists plain 256-bit stores, and excludes the masked-store forms handled by `VICTORY_PATCH_MASKED`.

**Important qualification:** 117,413 is the number of generated list lines, not the number of sites the runtime will successfully patch. The generator's stderr summary (total stores found and four-byte stores it could not safely cover) was not included in the terminal output supplied for this record. The runtime patcher independently checks each site's bytes and can refuse a site if a trampoline cannot be built; startup reports the actual `wide stores N split into 128-bit halves (M refused)` result. A successful generation command alone does not verify that RVA `0x4F48E54` is covered, or that any site has yet been patched in a game run.

#### Next controlled run

The loader source in `apps/victory/src/run.rs` confirms that an explicit `VICTORY_PATCH_MASKED` setting overrides the automatic Series 1.0.2.1 selection, which otherwise includes `all` plus eight build-specific plain wide-store RVAs. With the complete generated list enabled, use:

```bash
VICTORY_FAULT_TRACKING=1 \
VICTORY_PATCH_MASKED=all \
VICTORY_PATCH_WIDE=/tmp/victory-wide-sites.txt \
./Launch.sh
```

Here, `VICTORY_PATCH_MASKED=all` prevents the eight automatically-added plain wide-store RVAs from also being sent through the masked-store patcher; the generated `VICTORY_PATCH_WIDE` list is intended to handle the plain 256-bit stores. Do not append the previously hand-entered plain-store RVAs to `VICTORY_PATCH_MASKED` for this run.

The next startup log must be checked for all of the following:

1. `fault tracking on`
2. `masked stores N patched to plain stores`
3. `wide stores N split into 128-bit halves (M refused)`

Record both wide-store counts. In particular, a nonzero refused count is not automatically fatal, but it means some generated sites were not applied and the exception path may remain. Preserve the full log and capture any new Rosetta RIP and instruction bytes.

## 7. Current interpretation

### Confirmed

1. The tested game build is Series 1.0.2.1 with the hash recorded above.
2. Victory detects 1,234 masked/vector store candidates in the executable.
3. Fault-based title-memory tracking was off in the 2026-11-27 baseline; a 2026-11-28 follow-up confirmed it on.
4. The world-stage reports show multi-second frames, tens of gigabytes of title-memory copy traffic, and substantial texture-preparation work.
5. Some wave64 operations are refused where the two-half lowering cannot safely synchronize.
6. At least one mesh shader exceeded Metal's 32 KiB mesh-output limit.
7. Many draws were reported without host pipelines; the sampled reports showed zero such pipelines actively being made.
8. The 2026-11-27 baseline Rosetta exception was below the main image base and remained unattributed.
9. A 2026-11-28 tracking-enabled run confirmed fault tracking on, a mapped base of `0x6fffed550000`, and 1,242 patched stores; it then faulted at main-image RVA `0x22f7e6` on a `vmovups [r12+0x60], ymm0` instruction.
10. A subsequent run's supplied exception was at RVA `0x22f7f4` on `vmovups [r12+0x78], ymm0`, 14 bytes later. Its startup output confirmed `fault tracking on` and 1,244 patched stores, verifying that the two preceding sites were added to the patch set.
11. The next run's startup excerpt confirms `fault tracking on`, mapped base `0x6fffed550000`, and 1,245 patched stores. Its exception at `0x6fffee32821a` is therefore at confirmed main-image RVA `0xDD821A`; the supplied bytes also identify a second candidate store at RVA `0xDD8222`.
12. A further exception occurred at `0x6ffff2498e54`; the instruction at the RIP decodes to `vmovups [rsi], ymm4`. Relative to the last confirmed base, the candidate RVA is `0x4F48E54`, but the mapped base and patch count from this latest run are still required to confirm it.
13. The local cache search found one 120,181,760-byte image at `target/wineprefix-play/drive_c/users/crossover/AppData/Local/victory/cache/images/victory-image-b99f876b74d4a77f.dll`; the conventional CrossOver Bottles directory did not contain this cache.
14. `cargo xtask wide-stores` completed against that cached image and wrote 117,413 lines to `/tmp/victory-wide-sites.txt`. This confirms generation and file length only; it does not establish how many runtime sites will patch successfully.
11. A later exception was reported at `0x6fffee32821a`, with bytes decoding to two consecutive 256-bit `vmovups` stores. The same run's startup excerpt confirms the main-image base `0x6fffed550000` and 1,245 stores patched, giving confirmed main-image RVAs `0xDD821A` and `0xDD8222` for the two candidate sites.

### Strong performance lead

The wholesale title-memory-copy fallback is the most concrete explanation for the unusually large copy volume and multi-second CPU preparation. Restoring changed-page tracking safely is the highest-value performance experiment because it targets a measured cost and has an existing opt-in/patching path in the code.

### Still unproven

- Whether fault tracking can run stably on this macOS/Rosetta setup after every faulting plain 256-bit store in the executable and relevant title DLLs has been patched.
- How much of the current copy volume is avoidable versus memory that cannot be page-tracked.
- Which exact shader hashes account for the largest visually significant missing passes.
- Whether the black window is primarily due to dropped/refused pipelines, a later rendering/presentation problem, or more than one issue.
- Whether adding RVA `0x22f7f4` will allow that first store sequence to complete without another Rosetta exception.
- Whether adding the two newly decoded stores at RVAs `0xDD821A` and `0xDD8222` will let that part of the title proceed without another Rosetta exception.
- Whether RVA `0x4F48E54` is covered by an entry in `/tmp/victory-wide-sites.txt`; the generated file exists, but its contents have not yet been checked against this RVA.
- How many of the 117,413 generated entries the runtime patcher will apply versus refuse, and whether the previously identified Series 1.0.2.1 plain-store RVAs are covered by the list.
- Whether further unaligned 256-bit stores in the same sequence, or elsewhere in the title/DLL images, will produce additional Rosetta exceptions.

## 8. Recommended next experiments

1. **Preserve the current run as the baseline.** Keep the full log and record the environment switches used by the launcher. Do not compare runs if the shader cache, game build, output size, or launch options changed unnoticed.
2. **Run the generated wide-store patcher in a controlled test.** The exact cached image has been found and `/tmp/victory-wide-sites.txt` now contains 117,413 generated entries. Launch with `VICTORY_FAULT_TRACKING=1`, `VICTORY_PATCH_MASKED=all`, and `VICTORY_PATCH_WIDE=/tmp/victory-wide-sites.txt`. The explicit masked setting prevents the automatic eight plain-store RVAs from also being sent through the masked-store patcher; the generated list handles the plain 256-bit stores.
3. **Verify actual application, not just list generation.** Retain the startup lines for `masked stores N patched to plain stores` and `wide stores N split into 128-bit halves (M refused)`. The 117,413 list entries are not a promise that all sites will be patched. Check whether the entry covering RVA `0x4F48E54` is present and whether its runtime site is accepted.
4. **Retain the full log for the next attempt.** Record the patch counts and refused count, then capture the next RIP and instruction bytes if Rosetta still stops.
5. **Separate shader losses by hash and refusal reason.** Group wave64-lowering refusals, mesh-output-limit refusals, translation failures, host-pipeline creation refusals, and compilation timeouts. This will distinguish correctness gaps from scheduling/cache misses.
6. **Re-test the visual result after the above are isolated.** Record whether the window remains black, whether audio continues, and whether a frame/present counter advances.

## Source locations

The following implementation files explain the mechanisms discussed above:

- [`apps/victory/src/run.rs`](apps/victory/src/run.rs) — build identification, masked-store scan, fault-tracking report, automatic Series 1.0.2.1 patch RVAs, CLWB handling.
- [`crates/victory-gpu/src/watch.rs`](crates/victory-gpu/src/watch.rs) — Rosetta detection, fault-tracking default, guarded-page write tracking.
- [`crates/victory-loader/src/masked.rs`](crates/victory-loader/src/masked.rs) — AVX/vector store scanning and trampoline patching.
- [`xtask/src/wide_stores.rs`](xtask/src/wide_stores.rs) — offline disassembly and generation of the `VICTORY_PATCH_WIDE` site list.
- [`crates/victory-loader/src/wide.rs`](crates/victory-loader/src/wide.rs) — runtime validation and splitting of plain 256-bit stores into 128-bit halves.
- [`crates/victory-gpu/src/memory.rs`](crates/victory-gpu/src/memory.rs) and [`crates/victory-gpu/src/host.rs`](crates/victory-gpu/src/host.rs) — title-memory shadows, refresh/copy preparation, and per-frame reporting.
- [`crates/victory-shader/src/emit/lower/halves.rs`](crates/victory-shader/src/emit/lower/halves.rs) — wave64-on-wave32 lowering and cross-half refusal conditions.
- [`crates/victory-shader/src/emit/mesh_size.rs`](crates/victory-shader/src/emit/mesh_size.rs) and [`crates/victory-gpu/src/pipeline/host.rs`](crates/victory-gpu/src/pipeline/host.rs) — Metal mesh-output sizing and over-limit rejection.
- [`crates/victory-gpu/src/pipeline/schedule.rs`](crates/victory-gpu/src/pipeline/schedule.rs) and [`crates/victory-gpu/src/pipeline/make.rs`](crates/victory-gpu/src/pipeline/make.rs) — asynchronous host-pipeline workers, wait budgets, and dropped draws.

---

**Revision note:** The tested local revision was `8791724`. The repository's `main` branch subsequently advanced to `648d0851` with two commits affecting only `Launch.sh`; the source files used for this analysis were unchanged in that comparison. This document is being added to the current `main` branch.
