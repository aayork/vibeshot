#!/bin/bash
# Toggle: first run picks a region and starts a background capture-and-stitch
# loop; a second run (while one is active) stops it and hands off the final
# stitched image. Must be launched by Hyprland itself (see bindings.lua's
# hl.dsp.exec_cmd use) for the same reason capture.sh/record-gif.sh are —
# the one-time region pick needs slurp/hyprpicker, which breaks if launched
# as a child of omarchy-shell.
set -uo pipefail

PLUGIN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/aayork.vibeshot"

if [[ -L "$CACHE_DIR" ]]; then
  echo "aayork.vibeshot: $CACHE_DIR is a symlink, refusing to use it" >&2
  exit 1
fi
mkdir -p -m 700 "$CACHE_DIR"
if [[ ! -O "$CACHE_DIR" ]]; then
  echo "aayork.vibeshot: $CACHE_DIR is not owned by the current user, refusing to use it" >&2
  exit 1
fi

PID_FILE="$CACHE_DIR/scroll-capture.pid"
STATE_FILE="$CACHE_DIR/scroll-capture.workdir"
TICK_SECONDS=0.7
# Hard deadline for the background stitch loop below — if Stop is somehow
# never clicked, the loop still ends itself instead of running indefinitely.
MAX_DURATION=1800

notify_plugin() {
  omarchy-shell shell call aayork.vibeshot "$1" "${2:-}"
}

stop_and_finish() {
  local pid work_dir
  pid=$(cat "$PID_FILE" 2>/dev/null)
  work_dir=$(cat "$STATE_FILE" 2>/dev/null)
  rm -f "$PID_FILE" "$STATE_FILE"

  # $pid is setsid's PID from start_capture, which is also the process group
  # ID for the whole loop — signal the group (negative PID) so an in-flight
  # grim/python child gets cleaned up too, not just the loop's own shell.
  [[ -n "$pid" ]] && kill -- "-$pid" 2>/dev/null
  sleep 0.2
  [[ -n "$pid" ]] && kill -9 -- "-$pid" 2>/dev/null

  if [[ -z "$work_dir" || ! -f "$work_dir/stitched.png" ]]; then
    notify_plugin scrollFailed
    [[ -n "$work_dir" ]] && rm -rf -- "$work_dir"
    exit 1
  fi

  local final
  final=$(mktemp "$CACHE_DIR/scroll-XXXXXXXXXX.png")
  mv "$work_dir/stitched.png" "$final"
  rm -rf -- "$work_dir"
  notify_plugin scrollCaptured "$final"
}

start_capture() {
  local selection
  selection=$(omarchy-capture-region region) || exit 0
  [[ -n "$selection" ]] || exit 0

  # mktemp -d creates the directory itself, atomically and exclusively, with
  # an unpredictable name — nothing could have pre-positioned a symlink or
  # file at this path before we own it.
  local work_dir
  work_dir=$(mktemp -d "$CACHE_DIR/scrollwork-XXXXXXXXXX")
  local prev="$work_dir/prev.png"
  local stitched="$work_dir/stitched.png"

  grim -g "$selection" "$prev" || { rm -rf -- "$work_dir"; exit 1; }
  cp -- "$prev" "$stitched"

  # setsid gives the loop (and everything it spawns each tick) its own
  # process group, so stop_and_finish's group-kill above reaches a grim/
  # python call that's mid-flight, not just the sleep/while shell itself.
  # timeout is the hard deadline: MAX_DURATION after start, the loop is
  # killed even if Stop is never clicked; --kill-after backstops a TERM
  # that a synchronous grim/python child briefly delays.
  setsid timeout --kill-after=5 "$MAX_DURATION" bash -c '
    prev="$1"; stitched="$2"; selection="$3"; work_dir="$4"; tick="$5"; plugin_dir="$6"
    while true; do
      sleep "$tick"
      new="$work_dir/new.png"
      grim -g "$selection" "$new" 2>/dev/null || continue
      python3 "$plugin_dir/stitch-frame.py" "$prev" "$new" "$stitched" >>"$work_dir/log" 2>&1
      mv "$new" "$prev"
    done
  ' bash "$prev" "$stitched" "$selection" "$work_dir" "$TICK_SECONDS" "$PLUGIN_DIR" &
  local loop_pid=$!

  echo "$loop_pid" >"$PID_FILE"
  echo "$work_dir" >"$STATE_FILE"
  notify_plugin scrollStarted "$selection"
}

if [[ -f $PID_FILE ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
  stop_and_finish
else
  rm -f "$PID_FILE" "$STATE_FILE"
  start_capture
fi
