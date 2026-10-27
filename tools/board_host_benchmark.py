"""Compare host conversion/UDP costs with unchanged board and image data."""
import argparse
import importlib.util
import hashlib
import json
from pathlib import Path
import statistics
import time

from PIL import Image
from eth_image import UdpImageClient
from project_paths import ROOT, user_test_image
from uart_image import image_to_rgb565, rgb565_to_image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',action='store_true')
    parser.add_argument('--compare',action='store_true',help='Also load the local v1.3 baseline backup')
    args = parser.parse_args()
    out = ROOT/'tools/board_results_host'
    out.mkdir(exist_ok=True)
    path = user_test_image('1920x1080_fpga_copy.png')
    with Image.open(path) as original:
        image = original.convert('RGB')
    if args.baseline:
        encode,decode = image_to_rgb565,rgb565_to_image
    else:
        from rgb565_codec import encode_rgb565,decode_rgb565
        encode,decode = encode_rgb565,decode_rgb565
    reference = image_to_rgb565(image)
    expected = rgb565_to_image(reference,*image.size).tobytes()
    report = dict(status='running',kind='baseline' if args.baseline else 'optimized',
                  image=path.relative_to(ROOT).as_posix(),image_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                  bitstream_sha256=hashlib.sha256((ROOT/'project_eth/build/eth_img.bit').read_bytes()).hexdigest(),
                  client_sha256=hashlib.sha256((ROOT/'tools/eth_image.py').read_bytes()).hexdigest(),
                  codec_sha256=hashlib.sha256((ROOT/('tools/uart_image.py' if args.baseline else 'tools/rgb565_codec.py')).read_bytes()).hexdigest(),
                  codec_trials=[],network_trials=[])
    for trial in range(3):
        start = time.perf_counter()
        raw = encode(image)
        encoded = time.perf_counter()-start
        start = time.perf_counter()
        decoded = decode(raw,*image.size)
        elapsed = time.perf_counter()-start
        assert raw == reference and decoded.tobytes() == expected
        row = dict(trial=trial+1,encode_seconds=encoded,decode_seconds=elapsed)
        report['codec_trials'].append(row)
        print(row,flush=True)
    for trial in range(5):
        with UdpImageClient(window_size=32) as client:
            client.ping()
            start = time.perf_counter()
            received = client.transfer(reference,*image.size,0)
            elapsed = time.perf_counter()-start
            assert received == reference and client.active_window == 32
            row = dict(trial=trial+1,seconds=elapsed,useful_image_Mbps=len(reference)*8/elapsed/1e6,
                       retries=client.retry_count,datagrams=client.sent_datagrams)
            report['network_trials'].append(row)
            print(row,flush=True)
    if args.compare and not args.baseline:
        # Alternate independent old/new clients under the same host and link conditions.
        old_path = ROOT/'tools/backups/before_host_fast/eth_image.py'
        spec = importlib.util.spec_from_file_location('baseline_eth_client',old_path)
        old = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(old)
        report['alternating_trials'] = []
        for trial in range(5):
            order = [('baseline',old.UdpImageClient),('optimized',UdpImageClient)]
            if trial % 2:
                order.reverse()
            for kind,factory in order:
                with factory(window_size=32) as client:
                    client.ping()
                    start = time.perf_counter()
                    received = client.transfer(reference,*image.size,0)
                    elapsed = time.perf_counter()-start
                    assert received == reference
                    row = dict(kind=kind,trial=trial+1,seconds=elapsed,
                               useful_image_Mbps=len(reference)*8/elapsed/1e6,retries=client.retry_count)
                    report['alternating_trials'].append(row)
                    print(row,flush=True)
        report['alternating_medians'] = {
            kind:statistics.median(x['useful_image_Mbps'] for x in report['alternating_trials'] if x['kind']==kind)
            for kind in ('baseline','optimized')}
    report.update(status='passed',encode_median=statistics.median(x['encode_seconds'] for x in report['codec_trials']),
                  decode_median=statistics.median(x['decode_seconds'] for x in report['codec_trials']),
                  network_median=statistics.median(x['seconds'] for x in report['network_trials']))
    report['useful_image_Mbps'] = len(reference)*8/report['network_median']/1e6
    target = out/('baseline.json' if args.baseline else 'optimized.json')
    target.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print('PASS',report['kind'],report['useful_image_Mbps'],report['encode_median'],report['decode_median'])


if __name__ == '__main__':
    main()
