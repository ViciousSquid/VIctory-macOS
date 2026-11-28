# VIctory macOS — Agent Handoff

**Handoff date:** 2026-11-28 UTC  
**Purpose:** Continue the Rosetta synchronous-exception investigation with the generated plain 256-bit store patch list.  
**Primary record:** [FINDINGS.md](FINDINGS.md), especially §§6.3–6.4, §7 and §8.

## Mission

The current investigation has reached a controlled test of the `VICTORY_PATCH_WIDE` runtime patcher. The next agent should verify that the generated list covers the latest faulting instruction, launch one controlled run with fault tracking enabled and both patch mechanisms configured, then report the actual patch counts and next runtime outcome.

Do not claim that the problem is fixed merely because the site list was generated.

## Machine and privacy constraints

- Test machine: Apple M5 MacBook Air, 24 GB unified memory.
- OS: macOS Tahoe 26.
- Local checkout: `~/Developer/VIctory-macOS`.
- The game is run from a user-owned local copy. **Do not request, record in this repository, or transmit the absolute game-install path.**
- Do not upload game files, cache images, generated patch lists, full logs, or other local files. The generated list and logs should remain on the user's Mac. When asking for output, request only the relevant diagnostic lines and have the user redact personal paths or usernames.
- The normal launcher is `./Launch.sh`; it opens a local dialog for the user to paste the game executable path. The path is passed to the process and is not saved in the repository.

## Confirmed investigation state

### Game image and latest fault

- Game build previously identified by VIctory: Series 1.0.2.1.
- Executable hash recorded in `FINDINGS.md`: `b99f876b74d4a77f03af5f878223b27bd647b5c35a79d5decd9f716504239e93`.
- Latest supplied tracking-enabled startup excerpt: fault tracking `on`; mapped main image base `0x6fffed550000`; masked/vector stores patched: `1,247`.
- Latest supplied Rosetta exception:
  - `x86_rip=0x6ffff2498e54`
  - Instruction bytes begin `c5 fc 11 26`
  - Decodes to the four-byte VEX instruction `vmovups [rsi], ymm4`.
  - Relative to the same run's confirmed image base, candidate RVA is `0x4F48E54`.
- The standard masked-store patch path cannot patch this four-byte plain store in place: its relative jump needs at least five bytes. The wide-store generator can sometimes construct a patch site by moving safe adjacent instructions, but it can also leave a site unlisted when control-flow or instruction constraints prevent that.

### Correct cache location

The earlier search of `~/Library/Application Support/CrossOver/Bottles` found no Victory cache. That was the wrong prefix for this checkout.

`tools/macos/victory.sh` defaults `WINEPREFIX` to the checkout-local `target/wineprefix-play`, unless an external `WINEPREFIX` is explicitly set. The user found one large cached image under:

```text
target/wineprefix-play/drive_c/users/crossover/AppData/Local/victory/cache/images/
```

- Filename: `victory-image-b99f876b74d4a77f.dll`
- Size: 120,181,760 bytes (about 114.6 MiB).
- The user found it as the sole candidate matching `victory-image-*.dll` and larger than 80 MiB.

Do not switch the investigation back to the conventional CrossOver Bottles folder unless the active Wine prefix changes.

### Generated list

Homebrew LLVM was installed after `command -v llvm-objdump` returned no path. The user then successfully ran `cargo xtask wide-stores` with Homebrew LLVM on `PATH`.

Generated output:

```text
/tmp/victory-wide-sites.txt
117413 lines
```

This is **117,413 generated site-list entries**, not 117,413 confirmed runtime patches. The generator's stderr summary (total disassembled 256-bit stores and count of four-byte stores it could not safely cover) was not captured in the conversation. The runtime patcher also validates site bytes and may refuse individual entries.

The list contains RVAs and patch instructions only; it does not contain game assets. Keep it local.

## Source behaviour verified

The following implementation details were inspected on the repository's default branch:

1. `tools/macos/victory.sh` chooses `$ROOT/target/wineprefix-play` as the default prefix and exports it to Wine.
2. `apps/victory/src/run.rs` reads `VICTORY_PATCH_MASKED`. If the variable is unset for the known Series 1.0.2.1 hash, it automatically selects `all` plus eight build-specific plain-wide-store RVAs.
3. An explicitly supplied `VICTORY_PATCH_MASKED` value overrides that automatic selection.
4. `crates/victory-loader/src/masked.rs` interprets `VICTORY_PATCH_MASKED=all` as all scanned masked/vector-store candidates. It does not add the eight automatic RVAs when the variable was explicitly supplied as `all`.
5. `xtask/src/wide_stores.rs` generates entries for plain 256-bit stores and excludes masked forms; `crates/victory-loader/src/wide.rs` validates and applies those entries for `VICTORY_PATCH_WIDE`.
6. The runtime reports the actual wide-store patch result as `wide stores N split into 128-bit halves (M refused)`.

Therefore the intended test uses `VICTORY_PATCH_MASKED=all` for the scanned masked/vector stores, and the generated file through `VICTORY_PATCH_WIDE` for plain 256-bit stores. Do not append the older hand-entered plain-store RVAs to `VICTORY_PATCH_MASKED` for this test; avoid overlapping patch mechanisms.

## Exact next actions

### 1. Verify the generated entry covers RVA 0x4F48E54

Do this before launching. A site may begin before the store and cover it as an adjacent instruction, so check the byte range on each list line, not only for an exact first-column match.

Run from the repository root:

```bash
cd ~/Developer/VIctory-macOS || exit 1

python3 - <<'PY'
from pathlib import Path

path = Path("/tmp/victory-wide-sites.txt")
target = int("4f48e54", 16)
matches = []

for line_number, line in enumerate(path.read_text().splitlines(), 1):
    fields = line.split()
    if len(fields) < 3:
        continue
    try:
        start = int(fields[0], 16)
        length = int(fields[1], 10)
    except ValueError:
        continue
    if start <= target < start + length:
        matches.append((line_number, line))

print(f"List exists: {path.is_file()}")
print(f"List entries: {sum(1 for _ in path.open())}")
print(f"Sites covering RVA 0x{target:x}: {len(matches)}")
for line_number, line in matches:
    print(f"line {line_number}: {line}")
PY
```

Expected list length is 117,413. There should be one site covering the faulting RVA if the generator successfully included that four-byte store. If there are zero covering sites, **do not claim the latest fault is addressed and do not blindly launch this as the completed fix**. Continue by recovering the generator's stderr summary and investigating why that store was left out.

Optional but useful: regenerate while capturing both outputs separately so the summary is preserved:

```bash
cd ~/Developer/VIctory-macOS || exit 1
IMAGE="$PWD/target/wineprefix-play/drive_c/users/crossover/AppData/Local/victory/cache/images/victory-image-b99f876b74d4a77f.dll"
PATH="$(brew --prefix llvm)/bin:$PATH" cargo xtask wide-stores "$IMAGE" \
  > /tmp/victory-wide-sites.txt \
  2> /tmp/victory-wide-sites-summary.txt
cat /tmp/victory-wide-sites-summary.txt
wc -l /tmp/victory-wide-sites.txt
```

Keep the generated list and summary local. The summary should state how many 256-bit stores were found, how many sites were listed, and how many four-byte stores were left. Do not put the list or summary in GitHub.

### 2. Run one controlled launch

Only after verifying that the generated list covers `0x4F48E54`, launch:

```bash
cd ~/Developer/VIctory-macOS || exit 1
VICTORY_FAULT_TRACKING=1 \
VICTORY_PATCH_MASKED=all \
VICTORY_PATCH_WIDE=/tmp/victory-wide-sites.txt \
./Launch.sh
```

The environment assignments apply only to this launch and its child processes. `Launch.sh` will open its normal local executable-path dialog.

If capturing a log locally, use `set -o pipefail` first and do not upload the log:

```bash
set -o pipefail
VICTORY_FAULT_TRACKING=1 \
VICTORY_PATCH_MASKED=all \
VICTORY_PATCH_WIDE=/tmp/victory-wide-sites.txt \
./Launch.sh 2>&1 | tee /tmp/victory-wide-store-test.log
```

### 3. Verify runtime patch application

Retain these startup lines verbatim:

```text
build
fault tracking
mapped at
masked stores ... patched to plain stores
wide stores ... split into 128-bit halves (... refused)
```

Also retain any warning containing:

```text
not a masked store or a plain 256-bit store
```

Interpretation:

- `fault tracking on` confirms the experiment is using the intended memory tracking mode.
- The masked-store count confirms the `VICTORY_PATCH_MASKED=all` path ran.
- The wide-store patched and refused counts are the key new evidence. A refused count greater than zero means some generated sites were not applied; it is not proof that the specific faulting site was refused, so correlate it with the site-coverage check.
- Do not infer success from reaching the game window alone. Capture the next Rosetta exception, including `x86_rip`, instruction bytes, and the mapped image base from the **same run**.

### 4. Report back to the maintainer / next agent

Ask the user to provide only:

1. Whether the site-coverage check found an entry for `0x4F48E54`.
2. Generator stderr summary and list line count (if regenerated).
3. The five startup diagnostics above, plus any relevant warning.
4. Whether the run passed the previous fault, produced a new Rosetta fault, or reached a later stage; include the new RIP and bytes if present.
5. Whether the window showed frames, remained black, or audio continued without a visible image.

Do not ask the user to repeat the Mac model, repository path, cache path, or the already-recorded earlier fault details.

## Guardrails

- Do not edit the game executable, the cached image, or the generated list by hand.
- Do not add more one-off RVAs to `VICTORY_PATCH_MASKED` while the generated wide-store list is being tested.
- Do not run multiple VIctory instances concurrently. The launcher already stops and waits for its Wine server before a `run`.
- Do not describe 117,413 generated entries as 117,413 successful patches.
- Do not claim the four-byte fault is covered until the range check confirms it and the runtime reports the corresponding wide-store patch succeeded.
- Do not upload full logs, game data, cache files, local absolute install paths, or unredacted personal paths to GitHub.

## Key files

- `FINDINGS.md` — chronological evidence, measurements, exception decoding and investigation interpretation.
- `Launch.sh` — local GUI path prompt and normal launch wrapper.
- `tools/macos/victory.sh` — Wine prefix selection and actual VIctory process launch.
- `apps/victory/src/run.rs` — fault-tracking and masked/wide patch selection and startup report.
- `xtask/src/wide_stores.rs` — offline wide-store disassembly and site-list generator.
- `crates/victory-loader/src/masked.rs` — masked-store patching and explicit RVA handling.
- `crates/victory-loader/src/wide.rs` — wide-store list parsing, runtime site validation and trampoline patching.

**Current status:** generated list exists; site coverage for RVA `0x4F48E54` is not yet verified; no run using `VICTORY_PATCH_WIDE` has yet been reported.
