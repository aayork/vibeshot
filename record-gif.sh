#!/bin/bash
# Toggle: first run starts a region-picked recording, a second run (while one
# is active) stops it and converts to GIF. Must be launched by Hyprland
# itself (see bindings.lua's hl.dsp.exec_cmd use) — never as a child of
# omarchy-shell, for the same reason capture.sh is: a Quickshell-spawned
# slurp/hyprpicker breaks mid-selection.
set -uo pipefail

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

PID_FILE="$CACHE_DIR/gif-recording.pid"
VIDEO_FILE="$CACHE_DIR/gif-recording.path"
FPS=15
# Hard deadline: if the Stop button is somehow never clicked (crash, lost
# focus, whatever), the recording still ends on its own instead of running
# forever and filling the disk.
MAX_DURATION=1800

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
    # $pid is setsid's PID from start_recording, which is also the process
    # group ID for the whole recorder — signal the group (negative PID), not
    # just that one process, so nothing it spawned is left running.
    kill -SIGINT -- "-$pid" 2>/dev/null
    local count=0
    while kill -0 "$pid" 2>/dev/null && ((count < 50)); do
      sleep 0.1
      count=$((count + 1))
    done
    kill -9 -- "-$pid" 2>/dev/null
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

  # mktemp both picks an unpredictable name and creates the file exclusively
  # up front, so gpu-screen-recorder is never the first thing to touch this
  # path. setsid puts the recorder (and timeout, its direct parent here) in
  # its own process group, and timeout enforces MAX_DURATION as a hard
  # deadline even if stop_and_convert is never called — both make cleanup
  # reliable regardless of how the recording ends.
  local video
  video=$(mktemp "$CACHE_DIR/gif-XXXXXXXXXX.mp4")
  setsid timeout --signal=INT --kill-after=5 "$MAX_DURATION" \
    gpu-screen-recorder "${region_args[@]}" -f "$FPS" -fm cfr -fallback-cpu-encoding yes -o "$video" >/dev/null 2>&1 &
  local pid=$!

  # mktemp already created $video (empty) up front, so its mere existence no
  # longer indicates the recorder has actually started — wait for it to
  # become non-empty instead.
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [[ ! -s $video ]] && ((waited < 50)); do
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
