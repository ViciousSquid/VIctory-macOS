#!/bin/sh
# Launch an Xbox Series game build through VIctory on macOS.
#
# First-time setup is separate: run ./setup.sh once from the repository root.
# Then run ./Launch.sh and paste the full path to game_scarlett_master.exe.
# The selected path is used only by this local process and is not saved.

set -eu

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

ROOT=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "$ROOT"

[ -x "$ROOT/tools/macos/victory.sh" ] ||
    fail "VIctory launcher is missing from this checkout."

[ -f "$ROOT/victory.toml" ] ||
    fail "victory.toml is missing. Run ./setup.sh first."

WINE="$ROOT/target/wine-cx/bin/wine"
D3DMETAL="$ROOT/target/wine-cx/lib/external/D3DMetal.framework"

[ -x "$WINE" ] ||
    fail "the custom CrossOver Wine build is missing. Run ./setup.sh first."

[ -d "$D3DMETAL" ] ||
    fail "D3DMetal is missing from the custom Wine build. Complete the D3DMetal step in ./setup.sh."

GAME_EXE=$(/usr/bin/osascript <<'APPLESCRIPT'
try
    set answer to display dialog "Paste the full path to game_scarlett_master.exe." with title "VIctory — Select game executable" default answer "" buttons {"Cancel", "Launch"} default button "Launch" cancel button "Cancel"
    return text returned of answer
on error number -128
    return ""
end try
APPLESCRIPT
) || fail "could not open the game path dialog."

[ -n "$GAME_EXE" ] || fail "no game executable was selected."

# Accept paths pasted with matching single or double quotes.
case "$GAME_EXE" in
    \"*\") GAME_EXE=${GAME_EXE#\"}; GAME_EXE=${GAME_EXE%\"} ;;
    \'*\') GAME_EXE=${GAME_EXE#\'}; GAME_EXE=${GAME_EXE%\'} ;;
esac

# Expand a leading ~/ without evaluating arbitrary shell input.
case "$GAME_EXE" in
    "~/"*) GAME_EXE="$HOME/${GAME_EXE#\~/}" ;;
esac

case "${GAME_EXE##*/}" in
    game_scarlett_master.exe) ;;
    *) fail "select the game executable named game_scarlett_master.exe" ;;
esac

[ -f "$GAME_EXE" ] || fail "the selected executable does not exist."

GAME_DIR=${GAME_EXE%/*}
[ "$GAME_DIR" != "$GAME_EXE" ] || GAME_DIR="."
GAME_DIR=$(CDPATH= cd "$GAME_DIR" && pwd) ||
    fail "cannot access the selected game directory."

GAME_EXE="$GAME_DIR/game_scarlett_master.exe"
[ -f "$GAME_DIR/appdata0.rpf" ] ||
    fail "appdata0.rpf was not found beside the executable. VIctory expects package files directly in the game directory."

printf '\nVIctory macOS launcher\n'
printf 'Validating the selected game directory...\n'

# Pass the path only to this process and its children. Do not write it to
# victory.toml or any repository file.
export VICTORY_GAME_DIR="$GAME_DIR"
"$ROOT/tools/macos/victory.sh" config

printf '\nStarting VIctory through CrossOver Wine and D3DMetal...\n'
exec "$ROOT/tools/macos/victory.sh" run --execute "$GAME_EXE" "$@"
