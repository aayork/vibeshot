#!/bin/bash
# Toggle: first run starts a region-picked recording, a second run (while one
# is active) stops it and converts to GIF. Must be launched by Hyprland
# itself (see bindings.lua's hl.dsp.exec_cmd use) — never as a child of
# omarchy-shell, for the same reason capture.sh is: a Quickshell-spawned
# slurp/hyprpicker breaks mid-selection.
set -uo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/aayork.vibeshot"
mkdir -p "$CACHE_DIR"
PID_FILE="$CACHE_DIR/gif-recording.pid"
VIDEO_FILE="$CACHE_DIR/gif-recording.path"
FPS=15

notify_plugin() {
  omarchy-shell shell call aayork.vibeshot "$1" "${2:-}"
}

# omarchy-capture-region --match-monitor returns either "monitor:NAME" or a
# literal "X,Y WxH" already in slurp's format — normalize both to the
# latter so the plugin can draw a border around the exact captured area.
resolve_geometry() {
  local target="$1"
  if [[ $target == monitor:* ]]; then
    hyprctl monitors -j | jq -r --arg name "${target#monitor:}" \
      '.[] | select(.name == $name) | "\(.x),\(.y) \(.width)x\(.height)"'
  else
    echo "$target"
  fi
}

stop_and_convert() {
  local pid video
  pid=$(cat "$PID_FILE" 2>/dev/null)
  video=$(cat "$VIDEO_FILE" 2>/dev/null)
  rm -f "$PID_FILE" "$VIDEO_FILE"

  if [[ -n "$pid" ]]; then
    kill -SIGINT "$pid" 2>/dev/null
    local count=0
    while kill -0 "$pid" 2>/dev/null && ((count < 50)); do
      sleep 0.1
      count=$((count + 1))
    done
    kill -9 "$pid" 2>/dev/null
  fi

  if [[ -z "$video" || ! -f "$video" ]]; then
    notify_plugin gifFailed
    exit 1
  fi

  local gif="${video%.mp4}.gif"
  local palette="${video%.mp4}-palette.png"

  ffmpeg -y -i "$video" -vf "fps=$FPS,scale=800:-1:flags=lanczos,palettegen=stats_mode=diff" "$palette" -loglevel error
  ffmpeg -y -i "$video" -i "$palette" \
    -filter_complex "fps=$FPS,scale=800:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer" \
    "$gif" -loglevel error
  rm -f "$video" "$palette"

  if [[ -f "$gif" ]]; then
    notify_plugin gifReady "$gif"
  else
    notify_plugin gifFailed
  fi
}

start_recording() {
  local target
  target=$(omarchy-capture-region smart --match-monitor) || exit 0

  local region_args
  if [[ $target == monitor:* ]]; then
    region_args=(-w "${target#monitor:}")
  elif [[ $target =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]]; then
    region_args=(-w "${BASH_REMATCH[3]}x${BASH_REMATCH[4]}+${BASH_REMATCH[1]}+${BASH_REMATCH[2]}")
  else
    exit 0
  fi

  local video="$CACHE_DIR/gif-$(date +%s%N).mp4"
  gpu-screen-recorder "${region_args[@]}" -f "$FPS" -fm cfr -fallback-cpu-encoding yes -o "$video" >/dev/null 2>&1 &
  local pid=$!

  local waited=0
  while kill -0 "$pid" 2>/dev/null && [[ ! -f $video ]] && ((waited < 50)); do
    sleep 0.1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    echo "$pid" >"$PID_FILE"
    echo "$video" >"$VIDEO_FILE"
    notify_plugin gifStarted "$(resolve_geometry "$target")"
  fi
}

if [[ -f $PID_FILE ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
  stop_and_convert
else
  rm -f "$PID_FILE" "$VIDEO_FILE"
  start_recording
fi
