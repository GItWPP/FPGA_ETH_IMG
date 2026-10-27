"""Actual-board 720p25 Sobel acceptance; no 30 FPS workload is generated."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import struct
import time
import numpy as np
from PIL import Image
from eth_image import UdpImageClient
from rgb565_codec import encode_rgb565
from stream_sobel_reference import reference_gray8
from video_pipeline import VideoReader,VideoSession

ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def correctness(out):
    rows=[]
    with UdpImageClient(bind_ip='192.168.1.18',window_size=64) as client:
        for w,h in [(1,1),(1,17),(17,1),(7,9),(193,73),(1280,720),(1920,1080)]:
            raw=((np.arange(w*h,dtype=np.uint32)*73+139)&65535).astype('<u2').tobytes()
            expected=reference_gray8(raw,w,h)
            before=client.retry_count;started=time.perf_counter()
            result=client.transfer_sobel_stream(raw,w,h)
            elapsed=time.perf_counter()-started
            assert result==expected,(w,h,'pixel mismatch')
            rows.append(dict(width=w,height=h,seconds=elapsed,retries=client.retry_count-before,sha256=hashlib.sha256(result).hexdigest()))
            print('PASS stream size',w,h,round(elapsed,6),flush=True)
        raw=encode_rgb565(Image.open(ROOT/'test_img/test1.png').convert('RGB').resize((257,140)))
        expected=reference_gray8(raw,257,140)
        client.native_stream = False
        for fault in ['request','reply','start_reply','end_reply']:
            original_send,original_decode=client._send_datagram,client._decode_datagram
            dropped=[False]
            def send(encoded):
                _,cmd,_,seq,_=struct.unpack_from('<BBHHH',encoded,4)
                if fault=='request' and cmd==0x41 and seq==2 and not dropped[0]:
                    dropped[0]=True;return
                return original_send(encoded)
            def decode(data,source):
                reply=original_decode(data,source)
                if reply is not None and not dropped[0] and ((fault=='reply' and reply.cmd==0xc1 and reply.seq==1)
                    or (fault=='start_reply' and reply.cmd==0xc0) or (fault=='end_reply' and reply.cmd==0xc2)):
                    dropped[0]=True;return None
                return reply
            client._send_datagram,client._decode_datagram=send,decode
            before=client.retry_count
            try:result=client.transfer_sobel_stream(raw,257,140)
            finally:client._send_datagram,client._decode_datagram=original_send,original_decode
            assert dropped[0] and result==expected
            rows.append(dict(fault=fault,retries=client.retry_count-before,exact=True))
            print('PASS stream recovery',fault,client.retry_count-before,flush=True)
    return rows


def capacity(path):
    with VideoReader(path) as reader:image=reader.read_at(0)
    assert image.size==(1280,720)
    raw=encode_rgb565(image);expected=reference_gray8(raw,*image.size)
    trials=[]
    with UdpImageClient(bind_ip='192.168.1.18',window_size=64) as client:
        for trial in range(12):
            start=time.perf_counter();result=client.transfer_sobel_stream(raw,*image.size)
            elapsed=time.perf_counter()-start
            assert result==expected
            trials.append(elapsed)
    median=statistics.median(trials)
    print('720p network median',median,'seconds/frame',flush=True)
    return dict(seconds=trials,median_seconds=median,retries=client.retry_count,
                within_25fps_budget=median<=0.04,backend=client.stream_backend)


def video(path,out):
    with VideoReader(path) as reader:info=reader.info
    assert (info.width,info.height)==(1280,720) and abs(info.fps-25)<0.01,info
    wanted={0,info.frame_count//3,info.frame_count*2//3,info.frame_count-1}
    samples={};durations=[];indices=[]
    session=VideoSession(path,bind_ip='192.168.1.18',mode=5,bounds=None,realtime=False).start()
    deadline=time.monotonic()+max(60,info.duration*3)
    while not session.done.is_set() and time.monotonic()<deadline:
        pair=session.take_latest()
        if pair is not None:
            indices.append(pair.index);durations.append(pair.network_seconds)
            if pair.index in wanted:samples[pair.index]=pair
        time.sleep(0.001)
    pair=session.take_latest()
    if pair is not None:
        indices.append(pair.index);durations.append(pair.network_seconds)
        if pair.index in wanted:samples[pair.index]=pair
    if not session.done.is_set():
        session.stop();session.done.wait(2);raise TimeoutError('25 FPS video acceptance deadline')
    stats=session.snapshot()
    assert not session.error,session.error
    assert stats['processed']==info.frame_count and stats['skipped']==0,stats
    assert set(samples)==wanted,(set(samples),wanted)
    assert stats['processed_fps']>=24.8,stats
    assert stats['retries']==0,stats
    checked=[]
    for index,pair in sorted(samples.items()):
        raw=encode_rgb565(pair.source)
        assert pair.result.convert('L').tobytes()==reference_gray8(raw,*pair.source.size),(index,'reference mismatch')
        pair.source.save(out/f'frame_{index}_source.png');pair.result.save(out/f'frame_{index}_sobel.png')
        checked.append(dict(index=index,result_sha256=hashlib.sha256(pair.result.tobytes()).hexdigest()))
    print('PASS actual 720p25',stats,flush=True)
    return dict(stats=stats,source_fps=info.fps,source_frames=info.frame_count,source_sha256=sha(path),
                sample_checks=checked,observed_display_frames=len(indices),network_median=statistics.median(durations))


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--input',type=Path,default=ROOT/'test_video/test.mp4')
    parser.add_argument('--stage',choices=('correctness','capacity','video','all'),default='all')
    args=parser.parse_args();out=ROOT/'tools/board_results_stream';out.mkdir(exist_ok=True)
    report=dict(status='running',target_fps=25,bitstream_sha256=sha(ROOT/'project_eth/build/eth_img.bit'),
                input=str(args.input),client_sha256=sha(ROOT/'tools/eth_image.py'))
    try:
        if args.stage in ('correctness','all'):report['correctness']=correctness(out)
        if args.stage in ('capacity','all'):
            report['capacity']=capacity(args.input)
            assert report['capacity']['within_25fps_budget'],report['capacity']
        if args.stage in ('video','all'):report['video']=video(args.input,out)
        report['status']='passed'
    except Exception as exc:
        report.update(status='failed',error=repr(exc));raise
    finally:(out/f'{args.stage}.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':main()
