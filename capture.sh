#!/bin/bash
set -uo pipefail

MODE="${1:-smart}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/aayork.vibeshot"
mkdir -p "$CACHE_DIR"

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

FILE="$CACHE_DIR/capture-$(date +%s%N).png"
grim -g "$SELECTION" "$FILE" || exit 1
omarchy-shell shell call aayork.vibeshot captured "$FILE"
