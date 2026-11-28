# VIctory macOS — Rosetta runtime findings

**Updated:** 2026-11-28  
**Platform:** Apple M5 MacBook Air, 24 GB unified memory, macOS Tahoe  
**Game build:** Series 1.0.2.1  
**Game executable SHA-256:** \`b99f876b74d4a77f03af5f878223b27bd647b5c35a79d5decd9f716504239e93\`  
**Investigation source revision:** \`87917243b0560571e9ff8ab39479031cc5e4b70c\` (\`8791724\`)  

branch: https://github.com/ViciousSquid/VIctory-macOS/tree/patch/runtime-patch-data works at 4FPS on Macbook Air M5 
(use `Launch.sh` and select the EXE)


## Current result

**The game now runs with visible rendered frames without the recurring Rosetta crash, at approximately 4 FPS.** This is the latest user-reported runtime result.

The change that got past the recurring crash was to enable fault-based title-memory tracking and apply generated wide-store patch lists to both the main executable and the title-owned \`xboxbvhbuilder.dll\`.

The runtime confirmed that the generated lists were applied:

| Runtime patch path | Sites applied | Refused |
|---|---:|---:|
| Main executable — masked/vector-store patcher | 1,234 | No refused count in the supplied summary |
| Main executable — generated wide-store list | 117,413 | 0 |
| \`xboxbvhbuilder.dll\` — generated DLL wide-store list | 122 | 0 |

The two generated wide-store manifests contain **117,535 entries** in total. They are contributed upstream in [PR #656](https://github.com/pragyaangaur/VIctory-macOS/pull/656).

This is a meaningful change in execution status: the earlier run repeatedly stopped on Rosetta synchronous exceptions; with both wide-store lists applied, the inspected log no longer contained a later \`rosetta error:\` line, actual frames were visible, and the latest run remained active at about 4 FPS.

The crash issue is therefore **mitigated for the tested build and observed run**, not proven impossible in every scene or future session. Performance is still poor. A 4 FPS result is approximately 250 ms per frame and is not yet a usable performance target.

## Executive summary

The investigation began with the game reaching world startup but rendering either a black window with audio or extremely slowly. Initial frame reports were approximately **0.1–0.2 FPS**, with multi-second frame times and very large title-memory copy volumes.

The first run had fault-based title-memory tracking disabled. Victory consequently refreshed title-memory copies wholesale rather than relying on changed-page tracking. The supplied baseline reports showed approximately **27–28 GB of title-memory copy traffic per reported frame**, alongside expensive texture preparation.

Enabling fault tracking exposed a Rosetta limitation: certain unaligned 256-bit AVX stores could not be resumed after a guarded-page synchronous exception. The faults were not limited to the main executable. One recurring fault was attributed to the title-owned \`xboxbvhbuilder.dll\`.

The investigation moved from chasing individual faulting instruction addresses to generating complete wide-store manifests for the relevant images. At runtime, Victory's existing patcher split the listed 256-bit stores into 128-bit halves. The main-image list applied 117,413 sites, and the DLL list applied 122 sites, both with zero refusals.

After both lists were active, the observed process progressed into actual rendering without the previously recurring Rosetta exception. The current user-reported result is approximately 4 FPS. The primary remaining task is now performance profiling, not further speculative fault-site patching.

## 1. Test identity and baseline behaviour

The tested executable was identified as:

- **Game build:** Series 1.0.2.1
- **SHA-256:** \`b99f876b74d4a77f03af5f878223b27bd647b5c35a79d5decd9f716504239e93\`
- **Main image base in the captured runs:** \`0x6fffed550000\`
- **Preferred image base:** \`0x140000000\`
- **CLWB handling:** eight loops were made NOPs.

The initial warm log showed that Victory was doing substantial work before the rendering failure:

- D3D12 host pipelines were being created.
- Shader translation was progressing.
- DirectStorage read batches were completing.
- Host mesh pipelines were being created.
- The game reached world-stage frame reports.

The window was initially black while audio was audible. The early frame reports showed approximately 0.2 FPS and 0.1 FPS, with frame times of 4.38 seconds and 7.95 seconds.

Those early samples also reported approximately 27,018.7 MB and 28,092.7 MB of title-memory copies per frame. This was the key performance lead before the Rosetta fault-tracking work began.

## 2. Why fault tracking mattered

The initial startup explicitly reported:

~~~text
fault tracking off (title memory copied whole;
VICTORY_FAULT_TRACKING=1 turns it on, which also patches the stores Rosetta cannot resume)
~~~

Victory's normal title-memory tracking uses guarded 64 KiB pages to identify which pages have changed. The host can then refresh only the changed portions of title memory instead of copying every tracked range wholesale.

With fault tracking off, the supplied baseline logs show very large copy volumes. Enabling tracking was therefore important for reducing memory-copy overhead, but it also required the runtime to deal with Rosetta's inability to resume certain AVX stores after a synchronous page fault.

The relevant implementation is in:

- \`crates/victory-gpu/src/watch.rs\` — fault-tracking selection, Rosetta detection and store-patching requirement.
- \`crates/victory-loader/src/masked.rs\` — masked/vector-store scanning and trampoline patching.
- \`crates/victory-loader/src/wide.rs\` — validation and runtime splitting of plain 256-bit stores.
- \`apps/victory/src/run.rs\` — startup selection, patch configuration and diagnostics.

Fault tracking does not mean every title-memory range becomes page-tracked. Some memory remains on whole-range copy paths, so tracking is not expected to eliminate all memory-copy work.

## 3. Rosetta fault investigation

With fault tracking enabled, the recurring error was:

~~~text
rosetta error: unexpectedly need to EmulateForward on a synchronous exception
~~~

The exception reports supplied an x86 instruction pointer (RIP), ARM program counter, and instruction bytes. Converting the reported RIP to an image-relative address, then inspecting the bytes in the corresponding cached image, identified unaligned 256-bit \`vmovups\` stores.

### 3.1. Main-executable faults

The initial tracking-enabled runs identified a sequence of stores in the main executable:

| Main-image RVA | Decoded instruction |
|---|---|
| \`0x22f7e6\` | \`vmovups [r12+0x60], ymm0\` |
| \`0x22f7ed\` | \`vmovups [r12+0x40], ymm0\` |
| \`0x22f7f4\` | \`vmovups [r12+0x78], ymm0\` |

Later exceptions identified another pair of candidate stores:

| Main-image RVA | Decoded instruction |
|---|---|
| \`0xdd821a\` | \`vmovups [rax+0x320], ymm0\` |
| \`0xdd8222\` | \`vmovups [rax+0x340], ymm0\` |

A further reported instruction decoded as:

~~~asm
vmovups [rsi], ymm4
~~~

Its candidate main-image RVA was \`0x4f48e54\`, using the main-image base confirmed in that investigation sequence.

The instruction bytes and image-base arithmetic established that these faults were associated with plain 256-bit stores. Adding individual RVAs one at a time advanced the patch count, but another store could fault later. The investigation therefore moved to generating a complete list of eligible wide-store sites in the cached image.

### 3.2. DLL fault attribution

Patching the main executable alone did not clear the recurring exception. A later fault occurred at:

~~~text
x86_rip=0x6fffed474b2f
~~~

The module trace identified the cached image \`victory-image-2d3fbea0ca5034e7.dll\`, mapped at \`0x6fffed460000\`, as the title-owned \`xboxbvhbuilder.dll\`.

The module-relative fault address is:

~~~text
0x6fffed474b2f - 0x6fffed460000 = 0x14b2f
~~~

The faulting instruction at DLL RVA \`0x14b2f\` was:

~~~asm
vmovups [rax], ymm0
~~~

This established that the recurring exception was not confined to the main executable. The relevant title DLL needed its own wide-store manifest.

## 4. Generated patch data

The generator was run against the cached mapped images rather than against an assumed on-disk game executable path.

### 4.1. Main executable manifest

The cached main image was found under the checkout's Wine prefix:

~~~text
target/wineprefix-play/drive_c/users/crossover/AppData/Local/victory/cache/images/
~~~

The cached image was:

~~~text
victory-image-b99f876b74d4a77f.dll
~~~

It was 120,181,760 bytes (approximately 114.6 MiB).

The generator command was:

~~~bash
PATH="$(brew --prefix llvm)/bin:$PATH" cargo xtask wide-stores \
  "$PWD/target/wineprefix-play/drive_c/users/crossover/AppData/Local/victory/cache/images/victory-image-b99f876b74d4a77f.dll" \
  > /tmp/victory-wide-sites.txt
~~~

Generation completed and produced:

- **117,413 lines**
- **117,413 generated main-image patch-site entries**

The generated file contains site metadata (image-relative offsets, overwrite lengths and instruction pieces). It does not contain the game executable or game assets.

### 4.2. DLL manifest

The corresponding cached image for \`xboxbvhbuilder.dll\` had image size \`0xDE000\`. The recurring fault was at RVA \`0x14b2f\` in executable section \`.text\`.

The DLL generator produced:

- **122 patch-site entries**
- One generated site covering RVA \`0x14b2f\`
- **0 four-byte stores left uncovered**, according to the generator output

The exact site covering the observed fault was:

~~~text
14b2f 10 s4 c6
~~~

The site begins with the four-byte store and includes six adjacent movable bytes. The runtime applied all 122 generated DLL sites.

### 4.3. Committed repository files

The generated files are now committed in the fork:

| Repository path | Entries |
|---|---:|
| \`runtime-patches/victory-wide-sites.txt\` | 117,413 |
| \`runtime-patches/victory-wide-dlls/2d3fbea0ca5034e7.txt\` | 122 |
| **Total** | **117,535** |

The two manifests are submitted to the original project in:

**[PR #656 — Add generated Rosetta wide-store patch-site manifests](https://github.com/pragyaangaur/VIctory-macOS/pull/656)**

The PR contributes the generated data files. It does not add new runtime patching code or modify the executable. The existing loader consumes the manifests and performs the in-memory transformation during launch.

## 5. Runtime patch application

The successful tested configuration used:

~~~bash
VICTORY_FAULT_TRACKING=1
VICTORY_PATCH_MASKED=all
VICTORY_PATCH_WIDE=/tmp/victory-wide-sites.txt
VICTORY_PATCH_WIDE_DIR=/tmp/victory-wide-dlls
~~~

The settings serve separate purposes:

- \`VICTORY_FAULT_TRACKING=1\` enables guarded-page title-memory tracking.
- \`VICTORY_PATCH_MASKED=all\` applies the existing masked/vector-store patch path to the scanned candidates.
- \`VICTORY_PATCH_WIDE\` supplies the generated wide-store site list for the main executable.
- \`VICTORY_PATCH_WIDE_DIR\` supplies per-image lists for title-owned DLLs. The file is selected using the image hash prefix.

The runtime reported:

~~~text
fault tracking on
masked stores 1234 patched to plain stores

wide stores split into 128-bit halves
  patched=117413 refused=0

wide stores 117413 split into 128-bit halves (0 refused)

wide stores split into 128-bit halves
  patched=122 refused=0

wide stores of a title DLL split
  image=victory-image-2d3fbea0ca5034e7.dll
  n=122 refused=0

title dll xboxbvhbuilder.dll at 0x6fffed460000
~~~

The masked-store count and wide-store counts are different patch paths. The 117,413 and 122 figures refer to the generated wide-store manifests; they should not be confused with the 1,234 masked/vector-store count.

The wide-store patcher rewrites each accepted 256-bit store into two 128-bit halves. The loader validates the listed sites against the mapped image and can refuse a site if the expected bytes or patch conditions do not match. In this run, both generated lists were applied with zero refusals.

## 6. Runtime outcome after the patches

The observed result changed materially after both image manifests were applied:

- The process progressed into actual game rendering.
- Visible frames appeared rather than only a black window with audio.
- The inspected patched-run log contained no later \`rosetta error:\` line.
- The user reported that the game remained running, with the latest observed rate around **4 FPS**.

The absence of a later exception in the inspected log, together with the runtime's zero-refusal counts and the current running session, is strong evidence that these manifests address the recurring wide-store fault path encountered during this investigation.

It is not proof that every possible Rosetta fault has been eliminated. The result is established for the tested executable build and observed run.

## 7. Performance after the crash fix

The crash is no longer the immediate blocker, but the frame rate remains very low.

The earlier baseline reports, with fault tracking off, were:

| Report | FPS | Frame time | Title-memory copies |
|---|---:|---:|---:|
| Around frame 1611 | 0.2 | 4,375.4 ms | 27,018.7 MB |
| Around frame 1612 | 0.1 | 7,950.8 ms | 28,092.7 MB |

After fault tracking and both wide-store manifests were active, the supplied instrumented reports included:

| Timestamp UTC | FPS | Frame time | Preparing | Title-memory copies | Texture preparation | GPU time |
|---|---:|---:|---:|---:|---:|---:|
| 01:28:48.585 | 2.7 | 372.4 ms | 142.0 ms | 64.0 ms / 191.4 MB | 28.8 ms / 7.6 MB | 163.2 ms |
| 01:29:03.913 | 0.5 | 2,189.9 ms | 351.5 ms | 232.9 ms / 269.8 MB | 291.7 ms / 58.0 MB | 295.7 ms |
| 01:29:09.301 | 0.2 | 5,385.7 ms | 482.0 ms | 244.2 ms / 282.6 MB | 376.9 ms / 105.7 MB | 1,470.5 ms |

These samples are highly variable and are not a controlled benchmark. The latest user-reported runtime result is approximately **4 FPS**, which is an improvement in the current session but still far below the intended performance.

The earlier baseline's tens-of-gigabytes copy volume is consistent with the fault-tracking-off whole-copy path. The later reports show much smaller title-memory copy volumes in the sampled frames. This supports the conclusion that enabling tracking reduced that particular source of work. It does not establish that title-memory copies are now the only or dominant performance bottleneck.

### Remaining performance leads

1. **GPU execution varies substantially.** The supplied GPU-time reports ranged from 163.2 ms to 1,470.5 ms. This is large enough to warrant further investigation of GPU work and scene complexity.
2. **Texture preparation is still measurable.** The supplied samples show 7.6–105.7 MB of texture preparation per report frame.
3. **Host pipeline availability is incomplete in some samples.** The reports showed 388, 348 and 716 draws dropped without a host pipeline, while 3, 4 and 1 pipelines respectively were still being made. Those counters do not by themselves identify whether each missing pipeline was refused, still compiling, or unavailable for another reason.
4. **Memory pressure remains present.** The log reported host copies of title memory being released while memory was low. One event reported 183 copies and 81 MB released, with 831 copies subsequently made again. This confirms eviction/recreation activity, but not its exact contribution to frame time.
5. **Shader compatibility still has known limitations.** Some wave64 operations cannot be safely lowered to a 32-lane host in all synchronization/control-flow contexts. At least one mesh shader requested 34,816 bytes of output, exceeding Metal's 32,768-byte limit by 2,048 bytes. These can cause individual pipelines or draws to be unavailable, but they are separate from the Rosetta wide-store exception.

The frame-time categories are instrumented separately and should not be added together as though they are guaranteed to be disjoint. The supplied reports also show little or no queue/fence waiting in their title-submission breakdowns; this does not rule out long GPU execution.

## 8. What is established, and what is not

### Established by supplied logs and generated artifacts

- The tested executable is Series 1.0.2.1 with the SHA-256 recorded above.
- Fault tracking was off in the original baseline and on in the successful patched run.
- The original tracking-enabled exceptions included unaligned 256-bit stores in the main executable.
- A further recurring fault was attributed to \`xboxbvhbuilder.dll\` at RVA \`0x14b2f\`.
- The main manifest contains 117,413 entries and the DLL manifest contains 122.
- The runtime reported 117,413 main-image wide-store patches and 122 DLL wide-store patches, with zero refusals for both lists.
- The runtime separately reported 1,234 masked/vector stores patched.
- After both wide-store lists were applied, the inspected log showed no later Rosetta exception and actual rendered frames appeared.
- The latest user-reported state is a running game at approximately 4 FPS.

### Not yet established

- That the game will never encounter another Rosetta exception in a different scene, session or executable build.
- That every generated site is necessary; the manifests are broad generated lists, not a minimal fault-only list.
- That the current frame rate is stable across a longer session or a repeatable benchmark.
- Which exact GPU workloads account for the remaining frame-time spikes.
- Whether dropped host-pipeline draws are primarily due to translation refusals, host-pipeline creation refusals, compilation latency, or a combination.
- Whether the memory-pressure copy-release path contributes materially to the remaining stalls.
- Whether the remaining wave64 and mesh-output limitations explain any specific visible rendering defect in the current run.

## 9. Current launch configuration

From the repository root, the committed manifests can be selected directly instead of relying on the temporary files in \`/tmp\`:

~~~bash
VICTORY_FAULT_TRACKING=1 \
VICTORY_PATCH_MASKED=all \
VICTORY_PATCH_WIDE="$PWD/runtime-patches/victory-wide-sites.txt" \
VICTORY_PATCH_WIDE_DIR="$PWD/runtime-patches/victory-wide-dlls" \
./Launch.sh
~~~

This is the configuration corresponding to the successful runtime patch application described above. Confirm the startup output on every run; patch counts and refusal counts are the check that the manifests were actually loaded and applied.

Do not change the game executable, generated lists, or patch-selection settings during a performance comparison. Keep the executable hash and full run log with each measurement.

## 10. Next investigation priorities

The next phase should focus on performance and longer-session stability, not adding speculative individual fault RVAs.

1. **Confirm persistence:** run the current patched configuration through a longer repeatable gameplay segment and retain the complete log. Record whether the process remains free of Rosetta exceptions.
2. **Measure FPS and frame time consistently:** capture several consecutive reports in the same scene and distinguish rendered frames from simulation/update ticks.
3. **Profile GPU work:** identify expensive command lists, passes, and pipelines. Do not rely on \`VICTORY_GPU_TIMING\` for per-command attribution on macOS/D3DMetal where the source notes D3D12 timestamps may read as zero.
4. **Investigate dropped draws:** retain shader hashes and the actual translation or host-creation refusal reasons. Separate unsupported shader operations from pipelines that are merely not ready.
5. **Correlate memory pressure:** collect process memory, host video-memory budget/use, texture counts, descriptor-view counts and host-copy release/recreation counters in the same run.
6. **Avoid premature tuning:** do not disable host-copy release or increase memory retention without measuring the memory budget and determining whether eviction/recreation is responsible for the observed stalls.

## 11. Relevant source locations

- \`apps/victory/src/run.rs\` — executable identification, masked-store scan, fault-tracking report and patch selection.
- \`crates/victory-gpu/src/watch.rs\` — Rosetta detection and guarded-page title-memory tracking.
- \`crates/victory-loader/src/masked.rs\` — masked/vector-store scanning and patching.
- \`xtask/src/wide_stores.rs\` — offline generation of wide-store patch-site manifests.
- \`crates/victory-loader/src/wide.rs\` — runtime validation and splitting of plain 256-bit stores into 128-bit halves.
- \`crates/victory-loader/src/windows.rs\` — title-owned DLL mapping and per-image wide-store list application.
- \`crates/victory-gpu/src/memory.rs\` and \`crates/victory-gpu/src/host.rs\` — title-memory shadows, refresh/copy preparation and frame diagnostics.
- \`crates/victory-gpu/src/shadow.rs\` — low-memory release and recreation of title-memory host copies.
- \`crates/victory-gpu/src/texture.rs\` — texture preparation and staging.
- \`crates/victory-shader/src/emit/lower/halves.rs\` — wave64-on-wave32 lowering and unsupported cross-half cases.
- \`crates/victory-shader/src/emit/mesh_size.rs\` and \`crates/victory-gpu/src/pipeline/host.rs\` — mesh-output sizing and Metal-limit rejection.
- \`crates/victory-gpu/src/pipeline/schedule.rs\` and \`crates/victory-gpu/src/pipeline/make.rs\` — asynchronous host-pipeline compilation, wait budgets and dropped draws.

---

## Upstream contribution

The generated manifests described in this report are submitted for upstream review:

**[PR #656 — Add generated Rosetta wide-store patch-site manifests](https://github.com/pragyaangaur/VIctory-macOS/pull/656)**

The PR contains exactly these two generated data files:

- \`runtime-patches/victory-wide-sites.txt\` — 117,413 main-executable patch sites.
- \`runtime-patches/victory-wide-dlls/2d3fbea0ca5034e7.txt\` — 122 \`xboxbvhbuilder.dll\` patch sites.

The manifests preserve the generated site data. Runtime patching is performed by the existing VIctory loader when the corresponding environment settings are enabled.
