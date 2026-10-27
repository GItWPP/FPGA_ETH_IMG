"""Verify native 1920x1080 transfer and measure useful image-byte throughput."""
import argparse
import hashlib
import json
from pathlib import Path
import time
from PIL import Image
from eth_image import UdpImageClient, DEFAULT_HOST, DEFAULT_PORT
from project_paths import ROOT, user_test_image
from uart_image import image_to_rgb565, rgb565_to_image


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host',default=DEFAULT_HOST)
    parser.add_argument('--port',type=int,default=DEFAULT_PORT)
    parser.add_argument('--window',type=int,choices=(1,2,4,8,16,32,64),default=32)
    parser.add_argument('--repeat',type=int,default=3)
    parser.add_argument('--sweep',action='store_true',help='Compare windows 1, 2, 4, 8, 16, 32 and 64')
    args=parser.parse_args()
    path=user_test_image('1920x1080_fpga_copy.png')
    out=ROOT/'tools/board_results_eth_throughput'
    out.mkdir(exist_ok=True)
    with Image.open(path) as source:
        image=source.convert('RGB')
    assert image.size==(1920,1080)
    raw=image_to_rgb565(image)
    if not 1 <= args.repeat <= 20:
        parser.error('--repeat must be within 1..20')
    trials=[]
    for window in ((1,2,4,8,16,32,64) if args.sweep else (args.window,)):
        for trial in range(args.repeat):
            with UdpImageClient(args.host,args.port,window_size=window) as client:
                client.ping()
                start=time.perf_counter()
                result=client.transfer(raw,*image.size,0)
                elapsed=time.perf_counter()-start
                assert result==raw,'Full-HD pixels differ'
                assert client.active_window==window,'Requested window was not supported'
                row=dict(window=window,trial=trial+1,seconds=elapsed,
                         useful_image_Mbps=len(raw)*8/elapsed/1_000_000,
                         retries=client.retry_count,datagrams=client.sent_datagrams,window_peak=client.window_peak)
                trials.append(row)
                print(json.dumps(row),flush=True)
    selected=sorted((row for row in trials if row['window']==args.window),key=lambda row:row['seconds'])
    median=selected[len(selected)//2]
    elapsed=median['seconds']
    report=dict(status='passed',host=args.host,port=args.port,input=path.relative_to(ROOT).as_posix(),
                width=image.width,height=image.height,image_bytes=len(raw),seconds=elapsed,
                useful_image_MB_per_second=len(raw)/elapsed/1_000_000,
                useful_image_Mbps=len(raw)*8/elapsed/1_000_000,
                duplex_payload_Mbps=len(raw)*16/elapsed/1_000_000,
                retries=median['retries'],datagrams=median['datagrams'],window=args.window,
                bitstream_sha256=hashlib.sha256((ROOT/'project_eth/build/eth_img.bit').read_bytes()).hexdigest(),
                trials=trials,sha256=hashlib.sha256(result).hexdigest(),
                uart_1_5Mbps_8N1_duplex_payload_lower_bound_seconds=len(raw)*20/1_500_000,
                note='Median measured trial for selected window; useful image Mbps counts one RGB565 frame per complete round trip. Duplex payload counts both directions. Conversion, checking and display are outside the timer.')
    rgb565_to_image(result,*image.size).save(out/'copy_1920x1080.png')
    (out/'throughput.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False,indent=2),flush=True)


if __name__=='__main__':
    main()
