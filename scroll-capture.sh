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
mkdir -p "$CACHE_DIR"
PID_FILE="$CACHE_DIR/scroll-capture.pid"
STATE_FILE="$CACHE_DIR/scroll-capture.workdir"
TICK_SECONDS=0.7

notify_plugin() {
  omarchy-shell shell call aayork.vibeshot "$1" "${2:-}"
}

stop_and_finish() {
  local pid work_dir
  pid=$(cat "$PID_FILE" 2>/dev/null)
  work_dir=$(cat "$STATE_FILE" 2>/dev/null)
  rm -f "$PID_FILE" "$STATE_FILE"

  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  sleep 0.2
  [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null

  if [[ -z "$work_dir" || ! -f "$work_dir/stitched.png" ]]; then
    notify_plugin scrollFailed
    exit 1
  fi

  local final="$CACHE_DIR/scroll-$(date +%s%N).png"
  mv "$work_dir/stitched.png" "$final"
  rm -rf "$work_dir"
  notify_plugin scrollCaptured "$final"
}

start_capture() {
  local selection
  selection=$(omarchy-capture-region region) || exit 0
  [[ -n "$selection" ]] || exit 0

  local work_dir="$CACHE_DIR/scrollwork-$(date +%s%N)"
  mkdir -p "$work_dir"
  local prev="$work_dir/prev.png"
  local stitched="$work_dir/stitched.png"

  grim -g "$selection" "$prev" || { rm -rf "$work_dir"; exit 1; }
  cp "$prev" "$stitched"

  (
    while true; do
      sleep "$TICK_SECONDS"
      new="$work_dir/new.png"
      grim -g "$selection" "$new" 2>/dev/null || continue
      python3 "$PLUGIN_DIR/stitch-frame.py" "$prev" "$new" "$stitched" >>"$work_dir/log" 2>&1
      mv "$new" "$prev"
    done
  ) &
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
