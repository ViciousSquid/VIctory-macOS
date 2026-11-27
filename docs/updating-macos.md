# Updating and building VIctory on macOS

This guide takes an existing macOS checkout of VIctory to the latest code in
[ViciousSquid/VIctory-macOS](https://github.com/ViciousSquid/VIctory-macOS),
then rebuilds it and runs the available tests on Apple Silicon.

It covers both an existing checkout and a first-time setup. Run the commands
in Terminal, from the locations shown. Do not run them from a different
VIctory repository.

## 1. Check the Mac prerequisites

The macOS port requires:

- An Apple Silicon Mac (M1 or newer).
- macOS 15 Sequoia or newer.
- Rosetta 2.
- Xcode Command Line Tools.
- Homebrew.
- At least about 15 GB of free disk space before the first Wine build.

Check the machine architecture and macOS version:

```sh
uname -m
sw_vers -productVersion
```

The first command should print `arm64`. If Rosetta is not installed, install it:

```sh
softwareupdate --install-rosetta
```

Install the Xcode Command Line Tools if needed:

```sh
xcode-select --install
```

Homebrew is required by the setup script. Install it from
[brew.sh](https://brew.sh) if it is not already installed.

## 2. Open the macOS repository

### If you already have a local macOS checkout

Change to its root directory (the directory containing `setup.sh` and
`Cargo.toml`):

```sh
cd /path/to/VIctory-macOS
```

Confirm that this is the expected repository:

```sh
git remote -v
git status
```

Before updating, make sure you have no uncommitted changes. Commit or stash
your own work first. Do not discard changes just to make the update proceed.

Set `origin` to your fork:

```sh
git remote set-url origin https://github.com/ViciousSquid/VIctory-macOS.git
```

Add the original macOS project as `upstream`. The conditional makes this safe
to run whether or not that remote already exists:

```sh
if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream https://github.com/pragyaangaur/VIctory-macOS.git
else
  git remote add upstream https://github.com/pragyaangaur/VIctory-macOS.git
fi
```

### If you do not have a local macOS checkout yet

Clone your fork into a new directory:

```sh
mkdir -p ~/Developer
cd ~/Developer
git clone https://github.com/ViciousSquid/VIctory-macOS.git
cd VIctory-macOS
git remote add upstream https://github.com/pragyaangaur/VIctory-macOS.git
```

Keep this checkout separate from any other VIctory source tree.

## 3. Fetch and integrate the latest macOS source

Start from the `main` branch and make sure your local branch has the latest
version already pushed to your fork:

```sh
git switch main
git fetch origin
git pull --ff-only origin main
```

Fetch the original macOS repository and merge its latest `main` into your
branch:

```sh
git fetch upstream
git merge upstream/main
```

If Git reports that the branch is already up to date, there is nothing new to
merge. Otherwise, review and resolve any conflicts before continuing. Do not
use `git reset --hard` to bypass a conflict.

Push the updated branch to your fork:

```sh
git push origin main
```

Check the resulting revision and working tree:

```sh
git log -1 --oneline
git status --short
```

The working tree should be clean. The fork is the copy you build from; the
`upstream` remote is where you fetch future changes from the original macOS
project.

## 4. Obtain Apple's Game Porting Toolkit

The setup script adds Apple's D3DMetal framework to the CrossOver Wine build.
Apple distributes the toolkit as a download, so obtain it yourself:

1. Open [Apple Developer Downloads](https://developer.apple.com/download/all/?q=game%20porting%20toolkit).
2. Sign in with an Apple account.
3. Download the Game Porting Toolkit disk image.
4. Leave the downloaded `Game_Porting_Toolkit*.dmg` in your Downloads folder.

The setup script looks in Downloads automatically. If you saved the image
elsewhere, supply its path when running setup, for example:

```sh
GPTK_DMG="$HOME/Downloads/Game_Porting_Toolkit.dmg" ./setup.sh
```

Use the actual filename if it differs.

## 5. Run the setup and rebuild

From the repository root:

```sh
./setup.sh
```

The script is designed to be run again after updates. It checks the machine,
installs missing Homebrew dependencies, installs the pinned Rust toolchain
and Windows cross-compilation target, builds the x86_64 libraries, builds the
patched CrossOver Wine environment, adds D3DMetal, and builds VIctory.

Completed setup stages are reused where possible. On a first run, the Wine
build is the longest stage and the full setup can take about an hour. The
script checks for roughly 15 GB of free space before the first Wine build.

Do not delete the repository's `target/` directory as a routine update step.
It contains build products and the Wine environment that setup can reuse.

When setup finishes, it prints the next commands for configuring and running
VIctory.

## 6. Verify the build

Check that the rebuilt executable starts under the project's Wine environment:

```sh
tools/macos/victory.sh --version
```

This command builds the Windows-targeted VIctory executable for the macOS
Wine environment and runs its version command.

If the command reports that Wine or D3DMetal is missing, return to Step 5 and
read the setup error. Do not substitute an unrelated Wine installation
without first checking the paths and instructions in
[macOS port notes](macos.md).

## 7. Run the test suites

Run both test suites from the repository root.

### Native macOS tests

```sh
cargo test --workspace
```

These exercise the parts of the workspace that can run natively on macOS.

### Windows-targeted tests under Wine and D3DMetal

```sh
WINEDLLOVERRIDES="d3d12,d3d12core,dxgi=b" tools/macos/test-wine.sh --workspace --no-fail-fast
```

This builds the Windows target and runs its tests under the Wine environment
created by setup. The D3D12 DLL override makes the test run use D3DMetal.

Keep the output from both commands. A successful native test run alone does
not verify the D3D12 and shader paths exercised by the Wine test run. If a
test fails, record the failing test name and complete error output before
changing code or build dependencies.

## 8. Configure and run with your own game files

Building and running the test suites does not require game files. To try the
runtime, use your own legally obtained copy of the Xbox Series game build.
This repository does not include game files.

The setup creates `victory.toml` from `victory.example.toml` if the local
configuration does not already exist. Edit `victory.toml` and set
`game_dir` to the directory containing your game files. The package files
must be directly inside that directory; for example, `appdata0.rpf` must be
at `<game_dir>/appdata0.rpf`, not inside a separate `appdata0` subdirectory.

Check the configuration:

```sh
tools/macos/victory.sh config
```

Start the runtime with the path to the game's executable:

```sh
tools/macos/victory.sh run --execute /path/to/game_scarlett_master.exe
```

Replace the example path with the actual executable path in your own game
directory.

## 9. Updating again later

For subsequent source updates, repeat Step 3, then run:

```sh
./setup.sh
```

Then repeat Step 6 and Step 7. You normally do not need to rebuild Wine from
scratch: setup reuses completed stages and checks whether its Wine patches
need rebuilding.

Keep local changes and `victory.toml` safe when updating. Review
`git status` before merging, and never delete build folders or overwrite
configuration as a substitute for diagnosing an update problem.

## Troubleshooting and further reading

- [README](../README.md) — current project status, prerequisites, run
  instructions and test commands.
- [macOS port notes](macos.md) — implementation details, known Wine/D3DMetal
  differences and platform-specific troubleshooting.
- [Architecture](architecture.md) — the main VIctory components and how they
  fit together.

When reporting a problem, include the Mac model/chip, macOS version, the
latest commit hash, the exact command you ran, and the complete relevant
terminal output. Report native and Wine test results separately.
