"""Integer HOG v1: hard cell/bin votes, L1 Q10 blocks, signed linear SVM."""
from __future__ import annotations

FRAME_WIDTH, FRAME_HEIGHT = 320, 240
WINDOW_WIDTH, WINDOW_HEIGHT = 64, 128
STRIDE, CELL, BINS = 8, 8, 9
FEATURE_COUNT = 3780
SCORE_COUNT = 495
FEATURE_VERSION = 1


def gradient_bin(gx: int, gy: int) -> tuple[int, int]:
    """Unsigned 20-degree hard bins using fixed Q8 slope thresholds."""
    ax, ay = abs(gx), abs(gy)
    if ay == 0:
        return 0, ax
    scaled = ay * 256
    if scaled < ax * 93:
        index = 0
    elif scaled < ax * 215:
        index = 1
    elif scaled < ax * 443:
        index = 2
    elif scaled < ax * 1452:
        index = 3
    else:
        index = 4
    if (gx < 0) != (gy < 0):
        index = 8 - index
    return index, ax + ay


def cell_histograms(gray: bytes, width: int, height: int, region=None) -> list[int]:
    if len(gray) != width * height:
        raise ValueError("gray image length does not match its dimensions")
    x0, y0, rw, rh = region or (0, 0, width, height)
    if rw % CELL or rh % CELL or rw < CELL or rh < CELL:
        raise ValueError("HOG region dimensions must be positive multiples of 8")
    if x0 < 0 or y0 < 0 or x0 + rw > width or y0 + rh > height:
        raise ValueError("HOG region lies outside image")
    columns = rw // CELL
    hist = [0] * (columns * (rh // CELL) * BINS)
    for y in range(y0, y0 + rh):
        middle = y * width
        top, bottom = max(0, y - 1) * width, min(height - 1, y + 1) * width
        cell_row = ((y - y0) // CELL) * columns
        for x in range(x0, x0 + rw):
            gx = gray[middle + min(width - 1, x + 1)] - gray[middle + max(0, x - 1)]
            gy = gray[bottom + x] - gray[top + x]
            index, magnitude = gradient_bin(gx, gy)
            hist[(cell_row + (x - x0) // CELL) * BINS + index] += magnitude
    return hist


def block_features(hist: list[int], cell_columns: int, cell_rows: int) -> list[int]:
    if len(hist) != cell_columns * cell_rows * BINS:
        raise ValueError("histogram dimensions differ")
    features = []
    for y in range(cell_rows - 1):
        for x in range(cell_columns - 1):
            values = []
            for dy, dx in ((0, 0), (0, 1), (1, 0), (1, 1)):
                offset = ((y + dy) * cell_columns + x + dx) * BINS
                values.extend(hist[offset:offset + BINS])
            denominator = sum(values) + 1
            features.extend((value * 1024) // denominator for value in values)
    return features


def extract_window(gray: bytes, width=64, height=128, x=0, y=0) -> list[int]:
    hist = cell_histograms(gray, width, height, (x, y, WINDOW_WIDTH, WINDOW_HEIGHT))
    return block_features(hist, 8, 16)


def svm_scores(features, weights, bias, cell_columns=40, cell_rows=30) -> list[int]:
    if len(weights) != FEATURE_COUNT or len(features) != (cell_columns - 1) * (cell_rows - 1) * 36:
        raise ValueError("HOG model/feature geometry mismatch")
    result = []
    for wy in range(cell_rows - 15):
        for wx in range(cell_columns - 7):
            score, weight_offset = bias, 0
            for by in range(15):
                for bx in range(7):
                    offset = ((wy + by) * (cell_columns - 1) + wx + bx) * 36
                    for index in range(36):
                        score += features[offset + index] * weights[weight_offset + index]
                    weight_offset += 36
            result.append(min(2**31 - 1, max(-(2**31), score)))
    return result


def detect_reference(gray, weights=None, bias=None):
    if weights is None:
        from hog_model import WEIGHTS, BIAS
        weights, bias = WEIGHTS, BIAS
    hist = cell_histograms(gray, FRAME_WIDTH, FRAME_HEIGHT)
    features = block_features(hist, 40, 30)
    return svm_scores(features, weights, bias)


def nms(scores, threshold=0, overlap=0.35):
    """Return single-scale network-image boxes and raw signed scores."""
    candidates = [(index % 33 * STRIDE, index // 33 * STRIDE, WINDOW_WIDTH, WINDOW_HEIGHT, score)
                  for index, score in enumerate(scores) if score > threshold]
    candidates.sort(key=lambda box: box[4], reverse=True)
    result = []
    for candidate in candidates:
        x, y, width, height, score = candidate
        keep = True
        for bx, by, bw, bh, _ in result:
            intersection = max(0, min(x + width, bx + bw) - max(x, bx)) * max(0, min(y + height, by + bh) - max(y, by))
            if intersection / (width * height + bw * bh - intersection) > overlap:
                keep = False
                break
        if keep:
            result.append(candidate)
    return result
