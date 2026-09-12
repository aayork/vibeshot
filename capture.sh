#!/bin/bash
set -uo pipefail

MODE="${1:-smart}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/aayork.vibeshot"

# Refuse a cache dir that's a symlink (or owned by someone else) rather than
# blindly mkdir -p/writing through it — a symlink swapped in ahead of time
# could otherwise redirect our capture output anywhere on disk.
if [[ -L "$CACHE_DIR" ]]; then
  echo "aayork.vibeshot: $CACHE_DIR is a symlink, refusing to use it" >&2
  exit 1
fi
mkdir -p -m 700 "$CACHE_DIR"
if [[ ! -O "$CACHE_DIR" ]]; then
  echo "aayork.vibeshot: $CACHE_DIR is not owned by the current user, refusing to use it" >&2
  exit 1
fi

# A screenshot key pressed while a selection is already in progress cancels
# it (matches the stock omarchy-capture-screenshot convention) instead of
# stacking a second slurp/hyprpicker that fights the first for the cursor.
pkill slurp && exit 0

NO_HW_CURSORS=$(hyprctl getoption cursor:no_hardware_cursors -j | jq '.int')

set_no_hw_cursors() {
  hyprctl eval "hl.config({ cursor = { no_hardware_cursors = $1 } })" &>/dev/null ||
    hyprctl keyword cursor:no_hardware_cursors "$1" &>/dev/null
}

cleanup() {
  [[ -n "${FREEZE_PID:-}" ]] && kill "$FREEZE_PID" 2>/dev/null
  set_no_hw_cursors "$NO_HW_CURSORS"
}
trap cleanup EXIT

set_no_hw_cursors 0
{ read -r FREEZE_PID; read -r SELECTION; } < <(omarchy-capture-region "$MODE" --keep-freeze)

[[ -z "$SELECTION" ]] && exit 1

# mktemp creates the file itself, atomically and exclusively (refuses to
# follow a symlink or reuse an existing name) — safer than picking a
# timestamp-based name and letting grim be the first to create it, which
# leaves a window for something else to have pre-created that exact path.
FILE=$(mktemp "$CACHE_DIR/capture-XXXXXXXXXX.png")
grim -g "$SELECTION" "$FILE" || { rm -f "$FILE"; exit 1; }
omarchy-shell shell call aayork.vibeshot captured "$FILE"
