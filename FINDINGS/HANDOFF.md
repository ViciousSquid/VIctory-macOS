# VIctory macOS — Investigation handoff

**Updated:** 2026-11-28
**Repository:** ViciousSquid/VIctory-macOS
**Purpose:** Continue the Rosetta compatibility and Apple Silicon performance investigation from the current evidence. Read this file, then the report and captures in FINDINGS/.

## Start here

1. Read [FINDINGS/finding.md](FINDINGS/finding.md) for the full investigation history, executable identity, fault analysis, generated patches, launch configuration and the latest telemetry addendum.
2. Read [FINDINGS/results.txt](FINDINGS/results.txt) for the earlier process CPU/RSS capture, memory-pressure snapshot and truncated sample-profiler excerpt.
3. Read [FINDINGS/results2.txt](FINDINGS/results2.txt) for the complete 30-second powermetrics capture.

The diagnostics are now grouped under FINDINGS/. The root-level results.txt, results2.txt and FINDINGS.md have been moved; the canonical findings document is now FINDINGS/finding.md.

## Current execution status

- Tested game build: 1.0.2.1.
- Tested executable SHA-256: b99f876b74d4a77f03af5f878223b27bd647b5c35a79d5decd9f716504239e93.
- Platform: Apple M5 MacBook Air with 24 GB unified memory, macOS Tahoe.
- The user reported visible rendered frames at approximately 4 FPS after enabling fault tracking and applying generated wide-store manifests to both the main image and xboxbvhbuilder.dll.
- The current investigation phase is performance profiling and repeatability, not speculative addition of individual Rosetta fault addresses.

## Compatibility fix already established

The earlier recurring Rosetta synchronous-exception path was associated with unaligned 256-bit stores encountered while fault-based title-memory tracking was enabled. The broad generated manifests were applied successfully in the tested run:

| Patch path | Sites applied | Refused |
|---|---:|---:|
| Masked/vector-store patcher on main image | 1,234 | No refused count in supplied summary |
| Generated wide-store manifest for main image | 117,413 | 0 |
| Generated wide-store manifest for xboxbvhbuilder.dll | 122 | 0 |

The two wide-store manifests total 117,535 entries and are associated with upstream [PR #656](https://github.com/pragyaangaur/VIctory-macOS/pull/656). The exact launch configuration and source locations are documented in FINDINGS/finding.md.

Treat this as mitigation for the tested executable and observed run, not a guarantee that every possible Rosetta exception is fixed for all scenes or future builds.

## Latest hardware evidence

The 30-second results2.txt capture contains one-second samples from 04:07:50 to 04:08:19 UTC:

- Wine PID 48560 averaged 2,841 CPU ms/s (~2.84 logical-core equivalents).
- Two MTLCompilerService processes averaged 2,985 CPU ms/s combined (~2.99 core equivalents).
- ReportCrash averaged 930 CPU ms/s (~0.93 core equivalent), but this is not evidence that the Metal compiler crashed.
- GPU hardware active residency averaged 7.95%, ranging from 0.41% to 23.16%; GPU power averaged 126 mW and peaked at 859 mW.
- CPU power averaged 13.59 W.

Interpretation: substantial host CPU and Metal compiler-service activity is present, while the GPU is mostly idle across this capture but does become active intermittently. This points toward CPU-side runtime/driver/compiler work as a major lead. It does **not** establish that Metal compilation is the sole cause, that the GPU can never bottleneck, or that the 4 FPS result is caused by one component.

### Important correction: no Metal compiler crash

The user's DiagnosticReports search returned no matching compiler crash report, and the user confirmed that MTLCompilerService is not crashing. Do not repeat the earlier suspicion that the compiler is crashing. A ReportCrash process appears in powermetrics, but its presence alone does not identify a crashed process or establish a link to MTLCompilerService.

## Measurement caveats

- results.txt and results2.txt were captured about five minutes apart. Do not correlate their PIDs or per-process values as simultaneous measurements.
- results.txt contains a 30-second process sampler and only a truncated sample-profiler excerpt (first 140 lines). Its visible stack excerpt is dominated by AppKit and Wine/Rosetta syscall-dispatch frames, not useful gameplay hotspots.
- results2.txt is the complete 30-second hardware telemetry stream, not a full Instruments trace.
- GPU residency is a hardware activity indicator, not a direct per-frame GPU execution-time measurement.
- Keep host submission/fence wall time distinct from physical GPU execution time. The existing backend notes explain that D3D12 timestamp queries may not provide useful advancing timestamps on this macOS/D3DMetal path.
- The previous memory-pressure capture showed substantial available system memory; do not assume that 24 GB unified-memory capacity itself is the current bottleneck. Measure the relevant per-process footprint, allocations, copy traffic and eviction/recreation behaviour together.

## Next tasks, in order

1. **Establish a reproducible baseline.** Use the same executable hash, patch manifests, launch settings, scene and fixed observation interval. Record rendered FPS and frame-time samples, not just simulation TPS.
2. **Synchronise the measurements.** Capture the VIctory log, process CPU/RSS, full powermetrics output and a useful process profile over the same interval. Record start/end timestamps and PIDs.
3. **Test cold versus warm pipeline compilation.** Run once with the existing cache state, then repeat the same scene with the cache retained. Compare MTLCompilerService CPU time, pipeline creation counters, GPU residency and FPS. Do not delete caches as part of the comparison.
4. **Identify actual Wine CPU hotspots.** The previous macOS sample excerpt is not sufficient. Capture a full profile or use Instruments/targeted runtime markers if Rosetta/Wine stack unwinding hides the real functions.
5. **Check whether the GPU receives work consistently.** Correlate command submission, pipeline readiness, dropped draws, GPU active residency and rendered frames. Do not infer GPU saturation from CPU-side submission time.
6. **Only then choose an optimisation.** Candidate areas include pipeline cache/readiness and compilation scheduling, Wine/runtime CPU work, memory shadow/copy preparation, texture staging and GPU workload. Change one variable at a time.

## Do not regress the known-good configuration

- Keep fault tracking enabled for the tested compatibility path.
- Keep both generated wide-store manifests available and verify their runtime patched/refused counts on every test run.
- Preserve the tested executable SHA-256 and patch configuration during performance comparisons.
- Do not add guessed fault RVAs or widen patching further without a reproducible fault and instruction/module attribution.
- Do not describe the current evidence as proof that the game is GPU-bound, compiler-crashing, or memory-capacity-bound.

## Relevant implementation locations

- apps/victory/src/run.rs — executable identification, patch selection and startup diagnostics.
- crates/victory-gpu/src/watch.rs — Rosetta detection and fault-based title-memory tracking.
- crates/victory-loader/src/masked.rs — masked/vector-store patching.
- crates/victory-loader/src/wide.rs — wide-store validation and splitting.
- crates/victory-loader/src/windows.rs — title-owned DLL mapping and per-image manifest application.
- crates/victory-gpu/src/memory.rs and crates/victory-gpu/src/host.rs — title-memory shadows and host-copy preparation.
- crates/victory-gpu/src/shadow.rs — low-memory host-copy release/recreation.
- crates/victory-gpu/src/texture.rs — texture preparation and staging.
- crates/victory-gpu/src/pipeline/schedule.rs and crates/victory-gpu/src/pipeline/make.rs — asynchronous host-pipeline compilation and dropped-draw scheduling.
- docs/backend.md — current D3D12 backend boundary and future native Metal backend work.

## Privacy note

The current copies of the diagnostic files were sanitised before being placed in FINDINGS/. The earlier unsanitised versions may still be present in Git history from commits preceding the sanitisation. Rewriting public history is a separate operation and should be coordinated carefully; do not claim historical copies have been erased.
