#!/bin/bash
set -uo pipefail

# Fixed, minimal PATH so grim/slurp/jq/hyprctl/etc. below always resolve to
# the real system binaries, never to something an attacker-writable
# directory earlier in an inherited PATH could shadow.
export PATH=/usr/bin:/bin

MODE="${1:-smart}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/aayork.vibeshot"

# Refuse a cache dir that's a symlink (or owned by someone else) rather than
# blindly mkdir -p/writing through it — a symlink swapped in ahead of time
# could otherwise redirect our capture output anywhere on disk. mkdir
# without -p fails atomically with EEXIST if something is already there
# (including a symlink), so the only way this ever creates the directory is
# if nothing existed at that name a moment ago — no separate check-then-act
# gap at creation time. The dir fd we open right after stays bound to the
# directory we just verified even if its name is swapped out from under us
# later, so every subsequent path built from CACHE_DIR is anchored to that
# original inode, not whatever the name currently resolves to.
if [[ -L "$CACHE_DIR" ]]; then
  echo "aayork.vibeshot: $CACHE_DIR is a symlink, refusing to use it" >&2
  exit 1
fi
mkdir -m 700 "$CACHE_DIR" 2>/dev/null
if [[ -L "$CACHE_DIR" || ! -d "$CACHE_DIR" || ! -O "$CACHE_DIR" ]]; then
  echo "aayork.vibeshot: $CACHE_DIR is not a directory we own, refusing to use it" >&2
  exit 1
fi
exec {CACHE_FD}<"$CACHE_DIR"
CACHE_DIR="/proc/self/fd/$CACHE_FD"

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
# $FILE is under our /proc/self/fd/N handle, which is only meaningful in
# *this* process — omarchy-shell is a different process, so it needs the
# real absolute pathname (which it re-verifies itself before touching it).
omarchy-shell shell call aayork.vibeshot captured "$(readlink -f -- "$FILE")"
