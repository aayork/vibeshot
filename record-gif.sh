#!/bin/bash
# Toggle: first run starts a region-picked recording, a second run (while one
# is active) stops it and converts to GIF. Must be launched by Hyprland
# itself (see bindings.lua's hl.dsp.exec_cmd use) — never as a child of
# omarchy-shell, for the same reason capture.sh is: a Quickshell-spawned
# slurp/hyprpicker breaks mid-selection.
set -uo pipefail

# Fixed, minimal PATH so gpu-screen-recorder/ffmpeg/hyprctl/etc. below always
# resolve to the real system binaries, never to something an
# attacker-writable directory earlier in an inherited PATH could shadow.
export PATH=/usr/bin:/bin

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/aayork.vibeshot"

# Refuse a cache dir that's a symlink rather than blindly mkdir -p/writing
# through it. mkdir without -p fails atomically with EEXIST if anything is
# already there (including a symlink), so this only ever creates the
# directory when nothing existed a moment ago. The dir fd opened right after
# stays bound to the directory we just verified even if its name is later
# swapped out from under us, so every path built from CACHE_DIR from here on
# is anchored to that original inode.
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
# /proc/self/fd paths only mean something inside *this* process, so anything
# that has to survive past it (a later invocation reading our state files,
# or omarchy-shell over IPC) needs the real, ordinary absolute path instead.
CACHE_DIR_REAL=$(readlink -f -- "$CACHE_DIR")

PID_FILE="$CACHE_DIR/gif-recording.pid"
VIDEO_FILE="$CACHE_DIR/gif-recording.path"
MAX_STATE_BYTES=4096
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

# Reads a small state file, refusing to follow a symlink and refusing
# anything suspiciously large (these should only ever hold one short line —
# an unbounded read here would otherwise let a same-user attacker who has
# pre-planted the file hand us an arbitrarily large string to buffer).
read_state_file() {
  local f="$1" size
  [[ -L "$f" ]] && return 1
  size=$(stat -c%s -- "$f" 2>/dev/null) || return 1
  ((size > MAX_STATE_BYTES)) && return 1
  cat -- "$f" 2>/dev/null
}

# The pid/video-path pair in our state files is reachable by any same-user
# process that can write into our 0700 cache dir — nothing stops another app
# from planting its own numbers there before we ever look. Blindly trusting
# them would let that attacker redirect our destructive cleanup (a
# process-group kill, ffmpeg reading an arbitrary file) whichever way they
# like. So neither value is used until both: (a) the video path resolves,
# with no symlink anywhere, to something that is still literally one of our
# own gif-recording files directly inside the verified cache dir, and (b)
# the pid is a live process whose own argv contains that exact video path —
# i.e. it must actually BE the recorder that was told to write there, not
# merely some other process an attacker happened to pick.
validate_state() {
  local pid="$1" video="$2" real_video video_re

  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$video" && ! -L "$video" ]] || return 1
  real_video=$(readlink -f -- "$video" 2>/dev/null) || return 1
  video_re="^${CACHE_DIR_REAL}/gif-[A-Za-z0-9]{10}\.mp4\$"
  [[ "$real_video" == "$video" && "$real_video" =~ $video_re ]] || return 1
  [[ -f "$real_video" ]] || return 1
  grep -Fqz -- "$real_video" "/proc/$pid/cmdline" 2>/dev/null || return 1
  return 0
}

stop_and_convert() {
  local pid video

  pid=$(read_state_file "$PID_FILE")
  video=$(read_state_file "$VIDEO_FILE")
  rm -f "$PID_FILE" "$VIDEO_FILE"

  if ! validate_state "$pid" "$video"; then
    echo "aayork.vibeshot: recording state did not verify, refusing to act on it" >&2
    notify_plugin gifFailed
    exit 1
  fi
  video=$(readlink -f -- "$video")

  # $pid is setsid's PID from start_recording, which (setsid/timeout both
  # exec their target in place rather than forking) is also gpu-screen-
  # recorder's own pid and its process group ID — signal the group
  # (negative PID), not just that one process, so nothing it spawned is
  # left running.
  kill -SIGINT -- "-$pid" 2>/dev/null
  local count=0
  while kill -0 "$pid" 2>/dev/null && ((count < 50)); do
    sleep 0.1
    count=$((count + 1))
  done
  kill -9 -- "-$pid" 2>/dev/null

  if [[ ! -f "$video" ]]; then
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

# Writes a small state file without ever following a pre-planted symlink:
# an existing symlink at $f (dangling or not) is unlinked first — unlink
# never follows — so the subsequent `>` always creates a fresh regular file,
# never writes through to whatever the symlink pointed at.
write_state_file() {
  local f="$1" content="$2"
  rm -f -- "$f"
  printf '%s\n' "$content" >"$f"
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
  # path. Resolved to its real absolute form immediately: everything past
  # this point (argv, state files, IPC) needs a path that still means the
  # same thing outside this process, which the /proc/self/fd-anchored form
  # from $CACHE_DIR does not. setsid puts the recorder (and timeout, its
  # direct parent here) in its own process group, and timeout enforces
  # MAX_DURATION as a hard deadline even if stop_and_convert is never
  # called — both make cleanup reliable regardless of how the recording ends.
  local video
  video=$(mktemp "$CACHE_DIR/gif-XXXXXXXXXX.mp4")
  video=$(readlink -f -- "$video")
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
    write_state_file "$PID_FILE" "$pid"
    write_state_file "$VIDEO_FILE" "$video"
    notify_plugin gifStarted "$(resolve_geometry "$target")"
  fi
}

EXISTING_PID=$(read_state_file "$PID_FILE" 2>/dev/null)
if [[ -f $PID_FILE && -n "$EXISTING_PID" ]] && [[ "$EXISTING_PID" =~ ^[0-9]+$ ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
  stop_and_convert
else
  rm -f "$PID_FILE" "$VIDEO_FILE"
  start_recording
fi
