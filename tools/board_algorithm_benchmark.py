"""Compare algorithm-clock profiles using identical physical-board inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import time

import numpy as np
from PIL import Image
from band_client import BandClient, prepare_band
from band_reference import decode_integer
from eth_image import UdpImageClient
from hog_client import HOGClient, prepare_hog
from hog_reference import detect_reference
from project_paths import ROOT, user_test_image
from rgb565_codec import encode_rgb565
from uart_image import reference


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=('baseline50','algorithm125'), required=True)
    parser.add_argument('--bitstream', type=Path, required=True)
    parser.add_argument('--repeat', type=int, default=5)
    args = parser.parse_args()
    if not 1 <= args.repeat <= 10:
        parser.error('--repeat must be 1..10')
    bit = args.bitstream.resolve()
    out = ROOT/'tools/board_results_algorithm_clock'
    out.mkdir(exist_ok=True)
    path = user_test_image('test1.png')
    with Image.open(path) as opened:
        image = opened.convert('RGB').resize((640,360), Image.Resampling.LANCZOS)
    raw = encode_rgb565(image)
    gray, _ = prepare_hog(image)
    band_path = user_test_image('1.png')
    with Image.open(band_path) as opened:
        band_image = opened.convert('L')
    band_raw = prepare_band(band_image)
    expected_hog = detect_reference(gray)
    expected_band = decode_integer(np.asarray(band_image))
    assert expected_band['status'] == 0
    result = dict(status='running', profile=args.profile,
                  algorithm_hz=50_000_000 if args.profile=='baseline50' else 125_000_000,
                  bitstream_sha256=sha(bit.read_bytes()), image=path.relative_to(ROOT).as_posix(),
                  image_sha256=sha(path.read_bytes()), raw_sha256=sha(raw), hog_gray_sha256=sha(gray),
                  band_image=band_path.relative_to(ROOT).as_posix(), band_gray_sha256=sha(band_raw),
                  client_sha256=sha((ROOT/'tools/eth_image.py').read_bytes()), window=32,
                  repeat=args.repeat, image_modes=[], hog=[], band=[])
    target = out/f'{args.profile}.json'
    def save():
        target.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    save()
    try:
        with UdpImageClient(window_size=32) as client:
            client.ping()
            for mode, name in ((0,'copy'),(1,'gray'),(2,'invert'),(6,'gamma'),
                               (3,'mean'),(4,'median'),(5,'sobel'),(7,'sharpen')):
                expected = reference(raw,mode,*image.size)
                assert client.transfer(raw,*image.size,mode) == expected
                trials = []
                for _ in range(args.repeat):
                    before = client.retry_count
                    start = time.perf_counter()
                    actual = client.transfer(raw,*image.size,mode)
                    elapsed = time.perf_counter()-start
                    assert actual == expected, name
                    trials.append(dict(seconds=elapsed,retries=client.retry_count-before))
                row = dict(name=name,mode=mode,size=list(image.size),trials=trials,
                           median_seconds=statistics.median(x['seconds'] for x in trials),
                           output_sha256=sha(expected))
                result['image_modes'].append(row)
                print(name,row['median_seconds'],flush=True)
                save()
            hog = HOGClient(client)
            assert hog.detect(gray) == expected_hog
            for _ in range(args.repeat):
                start = time.perf_counter()
                scores = hog.detect(gray)
                elapsed = time.perf_counter()-start
                assert scores == expected_hog
                result['hog'].append(dict(seconds=elapsed,run_seconds=hog.calculation_seconds))
            band = BandClient(client)
            for _ in range(args.repeat):
                start = time.perf_counter()
                decoded = band.decode(band_raw,*band_image.size)
                elapsed = time.perf_counter()-start
                assert decoded.words == expected_band['cells']
                assert (decoded.rows,decoded.pitch_q8,decoded.detected_dots) == (expected_band['rows'],expected_band['pitch_q8'],expected_band['dots'])
                result['band'].append(dict(seconds=elapsed,run_seconds=decoded.calculation_seconds))
            result.update(status='passed', retries=client.retry_count,
                          hog_median_seconds=statistics.median(x['seconds'] for x in result['hog']),
                          hog_run_median_seconds=statistics.median(x['run_seconds'] for x in result['hog']),
                          band_median_seconds=statistics.median(x['seconds'] for x in result['band']),
                          band_run_median_seconds=statistics.median(x['run_seconds'] for x in result['band']))
    except Exception as exc:
        result.update(status='failed',error=repr(exc))
        save()
        raise
    save()
    print('PASS',args.profile,result['hog_run_median_seconds'],result['band_run_median_seconds'],flush=True)


if __name__ == '__main__':
    main()
