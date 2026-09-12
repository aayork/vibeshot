#!/usr/bin/env python3
"""Append the new-content slice of `new_frame` onto `stitched`, using
`prev_frame` (the previously captured raw frame, same crop region) to find
where the two overlap. Used by scroll-capture.sh once per captured tick.

Usage: stitch-frame.py <prev_frame> <new_frame> <stitched>
Prints one of APPENDED <n> / NOCHANGE / NOMATCH to stdout.
"""
import os
import stat
import sys
import numpy as np
from PIL import Image

PROBE_HEIGHT = 80
MIN_NEW_PIXELS = 6
# Mean abs channel difference (0-255 scale) below which two rows count as
# the same content — a little slack for compositor/encoding noise, not so
# much that distinct-but-similar content (e.g. a solid-color background)
# falsely matches.
MATCH_THRESHOLD = 6.0
# Repetitive content (large flat-color regions, repeating patterns) can give
# several y candidates near-identical scores. Blindly taking the global
# minimum then picks whichever the search happens to hit first, which can
# be a smaller y (less believed overlap) than the true alignment — and
# that direction fails by *duplicating* already-seen rows. Widening the
# match and preferring the largest y within a tolerance of the best score
# instead fails safe: worst case some new content is skipped, never
# duplicated.
TIE_TOLERANCE = 1.5

# scroll-capture.sh's work_dir sits in a 0700 directory, but any other
# process running as this user can still write into it (or race the grim
# call that's about to overwrite prev.png/new.png). None of these files are
# ours to trust blindly: cap what we'll even attempt to decode, in both
# byte size and decoded pixel count, so a maliciously swapped-in frame can't
# turn one stitch tick into a memory-exhaustion DoS via a decompression
# bomb, and refuse anything that isn't a plain regular file opened without
# following a symlink (grim/mv never produce one; something else must have).
MAX_FILE_BYTES = 64 * 1024 * 1024
Image.MAX_IMAGE_PIXELS = 64_000_000
# A screenshot region isn't reasonably ever this tall; stop growing the
# stitched image past this rather than let a very long capture session (up
# to MAX_DURATION in scroll-capture.sh) accumulate an unbounded amount of
# memory one small append at a time.
MAX_STITCHED_HEIGHT = 20000


def open_verified(path):
    """Open `path` for reading without following a symlink, and refuse
    anything that isn't a regular file under the size ceiling."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError(f"{path} is not a regular file")
        if st.st_size > MAX_FILE_BYTES:
            raise ValueError(f"{path} exceeds the {MAX_FILE_BYTES}-byte limit")
    except Exception:
        os.close(fd)
        raise
    return os.fdopen(fd, "rb")


def open_image_checked(f):
    """PIL only hard-errors at 2x Image.MAX_IMAGE_PIXELS, warning (but still
    decoding) between 1x and 2x — not the hard ceiling we actually want, so
    check the declared size ourselves before any pixel data is decoded."""
    im = Image.open(f)
    if im.size[0] * im.size[1] > Image.MAX_IMAGE_PIXELS:
        raise ValueError(f"image {im.size[0]}x{im.size[1]} exceeds the pixel-count limit")
    return im


def load_rgb(path):
    with open_verified(path) as f:
        return np.asarray(open_image_checked(f).convert("RGB"), dtype=np.int32)


def find_offset(probe, frame):
    ph = probe.shape[0]
    fh = frame.shape[0]
    if fh < ph:
        return None, None
    scores = np.empty(fh - ph + 1)
    for y in range(0, fh - ph + 1):
        scores[y] = np.abs(frame[y:y + ph] - probe).mean()
    best_score = scores.min()
    candidates = np.nonzero(scores <= best_score + TIE_TOLERANCE)[0]
    return int(candidates.max()), float(best_score)


def main():
    prev_path, new_path, stitched_path = sys.argv[1:4]
    prev = load_rgb(prev_path)
    new = load_rgb(new_path)

    if prev.shape[1] != new.shape[1]:
        print("NOMATCH")
        return

    probe_h = min(PROBE_HEIGHT, prev.shape[0])
    probe = prev[prev.shape[0] - probe_h:]

    y, score = find_offset(probe, new)
    if score is None or score > MATCH_THRESHOLD:
        print("NOMATCH")
        return

    new_content_start = y + probe_h
    new_rows = new.shape[0] - new_content_start
    if new_rows < MIN_NEW_PIXELS:
        print("NOCHANGE")
        return

    with open_verified(stitched_path) as f:
        stitched = open_image_checked(f).convert("RGB")

    if stitched.height + new_rows > MAX_STITCHED_HEIGHT:
        print("NOCHANGE")
        return

    with open_verified(new_path) as f:
        slice_img = open_image_checked(f).convert("RGB").crop(
            (0, new_content_start, new.shape[1], new.shape[0]))

    combined = Image.new("RGB", (stitched.width, stitched.height + slice_img.height))
    combined.paste(stitched, (0, 0))
    combined.paste(slice_img, (0, stitched.height))
    combined.save(stitched_path)

    print(f"APPENDED {new_rows}")


if __name__ == "__main__":
    main()
