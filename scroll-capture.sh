#!/bin/bash
# Toggle: first run picks a region and starts a background capture-and-stitch
# loop; a second run (while one is active) stops it and hands off the final
# stitched image. Must be launched by Hyprland itself (see bindings.lua's
# hl.dsp.exec_cmd use) for the same reason capture.sh/record-gif.sh are —
# the one-time region pick needs slurp/hyprpicker, which breaks if launched
# as a child of omarchy-shell.
set -uo pipefail

# Fixed, minimal PATH so grim/python3/etc. below always resolve to the real
# system binaries, never to something an attacker-writable directory earlier
# in an inherited PATH could shadow.
export PATH=/usr/bin:/bin

PLUGIN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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

PID_FILE="$CACHE_DIR/scroll-capture.pid"
STATE_FILE="$CACHE_DIR/scroll-capture.workdir"
MAX_STATE_BYTES=4096
TICK_SECONDS=0.7
# Hard deadline for the background stitch loop below — if Stop is somehow
# never clicked, the loop still ends itself instead of running indefinitely.
MAX_DURATION=1800

notify_plugin() {
  omarchy-shell shell call aayork.vibeshot "$1" "${2:-}"
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

# The pid/work_dir pair in our state files is reachable by any same-user
# process that can write into our 0700 cache dir — nothing stops another app
# from planting its own values there before we ever look. work_dir in
# particular feeds `rm -rf --`, so blindly trusting it (e.g. an attacker
# writing "$HOME" into the state file) would let that attacker turn our own
# cleanup into an arbitrary recursive delete. Neither value is used until
# both: (a) work_dir resolves, with no symlink anywhere, to a directory that
# is still literally one of our own scrollwork-* directories directly inside
# the verified cache dir — an exact, anchored shape that a string like
# "$HOME" or "/" can never match — and (b) the pid is a live process whose
# own argv contains that exact work_dir, i.e. it must actually BE the loop
# that was started against it, not merely some other process an attacker
# happened to pick.
validate_state() {
  local pid="$1" work_dir="$2" real_dir dir_re

  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$work_dir" && ! -L "$work_dir" ]] || return 1
  real_dir=$(readlink -f -- "$work_dir" 2>/dev/null) || return 1
  dir_re="^${CACHE_DIR_REAL}/scrollwork-[A-Za-z0-9]{10}\$"
  [[ "$real_dir" == "$work_dir" && "$real_dir" =~ $dir_re ]] || return 1
  [[ -d "$real_dir" ]] || return 1
  grep -Fqz -- "$real_dir" "/proc/$pid/cmdline" 2>/dev/null || return 1
  return 0
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

stop_and_finish() {
  local pid work_dir

  pid=$(read_state_file "$PID_FILE")
  work_dir=$(read_state_file "$STATE_FILE")
  rm -f "$PID_FILE" "$STATE_FILE"

  if ! validate_state "$pid" "$work_dir"; then
    echo "aayork.vibeshot: recording state did not verify, refusing to act on it" >&2
    notify_plugin scrollFailed
    exit 1
  fi
  work_dir=$(readlink -f -- "$work_dir")

  # $pid is setsid's PID from start_capture, which (setsid/timeout both exec
  # their target in place rather than forking) is also the loop's own pid
  # and its process group ID — signal the group (negative PID) so an
  # in-flight grim/python child gets cleaned up too, not just the loop's own
  # shell.
  kill -- "-$pid" 2>/dev/null
  sleep 0.2
  kill -9 -- "-$pid" 2>/dev/null

  if [[ ! -f "$work_dir/stitched.png" ]]; then
    notify_plugin scrollFailed
    rm -rf -- "$work_dir"
    exit 1
  fi

  local final
  final=$(mktemp "$CACHE_DIR/scroll-XXXXXXXXXX.png")
  final=$(readlink -f -- "$final")
  mv -- "$work_dir/stitched.png" "$final"
  rm -rf -- "$work_dir"
  notify_plugin scrollCaptured "$final"
}

start_capture() {
  local selection
  selection=$(omarchy-capture-region region) || exit 0
  [[ -n "$selection" ]] || exit 0

  # mktemp -d creates the directory itself, atomically and exclusively, with
  # an unpredictable name — nothing could have pre-positioned a symlink or
  # file at this path before we own it. Resolved to its real absolute form
  # immediately: everything past this point (the loop's own argv, state
  # files, IPC) needs a path that still means the same thing outside this
  # process, which the /proc/self/fd-anchored form from $CACHE_DIR does not.
  local work_dir
  work_dir=$(mktemp -d "$CACHE_DIR/scrollwork-XXXXXXXXXX")
  work_dir=$(readlink -f -- "$work_dir")
  local prev="$work_dir/prev.png"
  local stitched="$work_dir/stitched.png"

  grim -g "$selection" "$prev" || { rm -rf -- "$work_dir"; exit 1; }
  cp -- "$prev" "$stitched"

  # setsid gives the loop (and everything it spawns each tick) its own
  # process group, so stop_and_finish's group-kill above reaches a grim/
  # python call that's mid-flight, not just the sleep/while shell itself.
  # timeout is the hard deadline: MAX_DURATION after start, the loop is
  # killed even if Stop is never clicked; --kill-after backstops a TERM
  # that a synchronous grim/python child briefly delays. The per-tick log is
  # overwritten (not appended) each time so a long recording can't grow it
  # without bound — we only ever care about the most recent failure anyway.
  setsid timeout --kill-after=5 "$MAX_DURATION" bash -c '
    prev="$1"; stitched="$2"; selection="$3"; work_dir="$4"; tick="$5"; plugin_dir="$6"
    while true; do
      sleep "$tick"
      new="$work_dir/new.png"
      grim -g "$selection" "$new" 2>/dev/null || continue
      python3 "$plugin_dir/stitch-frame.py" "$prev" "$new" "$stitched" >"$work_dir/log" 2>&1
      mv "$new" "$prev"
    done
  ' bash "$prev" "$stitched" "$selection" "$work_dir" "$TICK_SECONDS" "$PLUGIN_DIR" &
  local loop_pid=$!

  write_state_file "$PID_FILE" "$loop_pid"
  write_state_file "$STATE_FILE" "$work_dir"
  notify_plugin scrollStarted "$selection"
}

EXISTING_PID=$(read_state_file "$PID_FILE" 2>/dev/null)
if [[ -f $PID_FILE && -n "$EXISTING_PID" ]] && [[ "$EXISTING_PID" =~ ^[0-9]+$ ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
  stop_and_finish
else
  rm -f "$PID_FILE" "$STATE_FILE"
  start_capture
fi
