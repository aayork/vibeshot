#!/usr/bin/env python3
"""Append the new-content slice of `new_frame` onto `stitched`, using
`prev_frame` (the previously captured raw frame, same crop region) to find
where the two overlap. Used by scroll-capture.sh once per captured tick.

Usage: stitch-frame.py <prev_frame> <new_frame> <stitched>
Prints one of APPENDED <n> / NOCHANGE / NOMATCH to stdout.
"""
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


def load_rgb(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.int32)


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

    slice_img = Image.open(new_path).convert("RGB").crop(
        (0, new_content_start, new.shape[1], new.shape[0]))
    stitched = Image.open(stitched_path).convert("RGB")

    combined = Image.new("RGB", (stitched.width, stitched.height + slice_img.height))
    combined.paste(stitched, (0, 0))
    combined.paste(slice_img, (0, stitched.height))
    combined.save(stitched_path)

    print(f"APPENDED {new_rows}")


if __name__ == "__main__":
    main()
