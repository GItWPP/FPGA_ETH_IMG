"""Integer acceptance model for the FPGA dark-dot band decoder.

This model is used by tests only. The GUI sends unfiltered gray8 pixels and uses
the coordinates and bits returned by the FPGA; it does not call this detector.
"""
from __future__ import annotations
import numpy as np

MAX_CELLS = 4096
THRESHOLD = 35


def find_dots(gray, threshold=THRESHOLD):
    g = np.asarray(gray, dtype=np.int32)
    h, w = g.shape
    p = np.pad(g, 4, mode='edge')
    ring = sum(p[4+dy:4+dy+h, 4+dx:4+dx+w] for dx, dy in
               [(-4, 0), (4, 0), (0, -4), (0, 4), (-3, -3), (3, -3), (-3, 3), (3, 3)])
    contrast = (ring >> 3) - g
    q = np.pad(g, 4, constant_values=256)
    minimum = np.ones(g.shape, dtype=bool)
    for dy in range(-4, 5):
        for dx in range(-4, 5):
            if dx == dy == 0:
                continue
            neighbor = q[4+dy:4+dy+h, 4+dx:4+dx+w]
            minimum &= (g < neighbor) if dy < 0 or (dy == 0 and dx < 0) else (g <= neighbor)
    ys, xs = np.where(minimum & (contrast >= threshold))
    return [(int(x), int(y), int(contrast[y, x])) for x, y in zip(xs, ys)]


def group_dots(dots):
    groups = []
    for dot in dots:
        if not groups or dot[1] - groups[-1][-1][1] > 5:
            groups.append([dot])
        else:
            groups[-1].append(dot)
    groups = [g for g in groups if len(g) >= 5]
    bands = []
    for g in groups:
        y = sum(p[1] for p in g) // len(g)
        if not bands or y - bands[-1][-1][0] > 24:
            bands.append([])
        bands[-1].append((y, g))
    return max(bands, key=len) if bands else []


def decode_integer(gray):
    g = np.asarray(gray, dtype=np.uint8)
    height, width = g.shape
    if not (16 <= width <= 512 and 16 <= height <= 512):
        raise ValueError('Band v1 requires native gray8 dimensions within 16..512')
    dots = find_dots(g)
    if len(dots) > 2048:
        return dict(status=3, cells=[], rows=0, pitch_q8=0, dots=len(dots))
    rows = group_dots(dots)
    result = dict(status=0, cells=[], rows=len(rows), pitch_q8=0, dots=len(dots))
    if len(rows) < 4 or len(rows) > 64:
        result['status'] = 1
        return result
    span = intervals = 0
    for y, points in rows[-2:]:
        xs = [x for x, dy, c in points if abs(dy-y) <= 3]
        if len(xs) < 8:
            result['status'] = 2
            return result
        span += max(xs) - min(xs)
        intervals += len(xs) - 1
    pitch = (span << 8) // intervals
    result['pitch_q8'] = pitch
    if not 8*256 <= pitch <= 32*256:
        result['status'] = 4
        return result
    for index, (y, points) in enumerate(rows):
        points = [(x, dy, c) for x, dy, c in points if abs(dy-y) <= 3]
        hist = [0]*32
        for x, dy, c in points:
            hist[((x << 8) % pitch) >> 8] += 1
        base = max(range(32), key=lambda n: hist[n]) << 8
        residuals = []
        for x, dy, c in points:
            r = (x << 8) % pitch - base
            if r > pitch//2:
                r -= pitch
            elif r < -pitch//2:
                r += pitch
            if abs(r) <= 3*256:
                residuals.append(r)
        if not residuals:
            result['status'] = 5
            return result
        total = sum(residuals)
        phase = (base + (abs(total)//len(residuals)) * (1 if total >= 0 else -1)) % pitch
        xq = phase - pitch
        row_cells = []
        while xq <= (width-1)*256+3*256:
            x = (xq + 128) // 256
            matches = [(dx, dy, c) for dx, dy, c in points if abs((dx << 8)-xq) <= 3*256]
            bit = bool(matches)
            # Never invent blank sites outside the acquired image.
            if 0 <= x <= width-1 or bit and -3 <= x <= width+2:
                partial = x < 3 or x > width-4
                low = partial or len(residuals)*4 < len(points)*3 or (bit and max(p[2] for p in matches) < 45)
                word = (max(0, min(width-1, x)) | (y << 9) | (int(bit) << 18)
                        | (int(index >= len(rows)-2) << 19) | (int(partial) << 20)
                        | (int(low) << 21) | (index << 22))
                row_cells.append(word)
            xq += pitch
        if index >= len(rows)-2 and sum((w >> 18) & 1 for w in row_cells)*10 < len(row_cells)*9:
            result['status'] = 2
        result['cells'].extend(row_cells)
    if len(result['cells']) > MAX_CELLS:
        result['status'] = 3
        result['cells'] = []
    return result
