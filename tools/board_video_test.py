"""Measure real file playback against the ZU4EV and independently check samples."""
import hashlib
import json
import time
from pathlib import Path

from hog_client import prepare_hog,draw_detections
from hog_reference import detect_reference
from hog_model import THRESHOLD
from project_paths import ROOT
from uart_image import reference
from video_pipeline import VideoSession,VideoReader,encode_rgb565,decode_rgb565


def check_pair(pair,mode):
    if mode == 8:
        gray,geometry = prepare_hog(pair.source)
        scores = detect_reference(gray)
        assert scores == pair.details['scores'],'Video HOG scores differ'
        result,_ = draw_detections(pair.source,scores,geometry,THRESHOLD)
        assert result.tobytes() == pair.result.tobytes()
    else:
        raw = encode_rgb565(pair.source)
        wanted = reference(raw,mode,*pair.source.size)
        assert decode_rgb565(wanted,*pair.source.size).tobytes() == pair.result.tobytes(),'Video pixels differ'


def main():
    path = ROOT/'test_video/fpga_demo.mp4'
    out = ROOT/'tools/board_results_video'
    out.mkdir(exist_ok=True)
    report = dict(status='running',bitstream_sha256=hashlib.sha256((ROOT/'project_eth/build/eth_img.bit').read_bytes()).hexdigest(),
                  video_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),cases=[])
    for name,mode,bounds in [('copy_320',0,(320,240)),('copy_640',0,(640,360)),
                             ('gamma_320',6,(320,240)),('sobel_320',5,(320,240)),('hog',8,(640,360))]:
        session = VideoSession(path,mode=mode,bounds=bounds).start()
        samples = []
        deadline = time.monotonic()+30
        while not session.done.is_set() and time.monotonic() < deadline:
            pair = session.take_latest()
            if pair is not None:
                if not samples:
                    samples.append(pair)
                elif len(samples) == 1:
                    samples.append(pair)
                else:
                    samples[1] = pair
            time.sleep(0.003)
        if not session.done.is_set():
            session.stop()
            session.done.wait(2)
            raise TimeoutError('Video board acceptance timed out')
        final = session.take_latest()
        if final is not None:
            samples = (samples[:1]+[final]) if samples else [final]
        assert session.error is None,session.error
        stats = session.snapshot()
        assert stats['state'] == 'finished' and stats['processed'] > 0
        assert stats['last_index'] == session.info.frame_count-1
        assert stats['processed']+stats['skipped'] == session.info.frame_count
        for pair in samples:
            check_pair(pair,mode)
        samples[-1].source.save(out/f'{name}_source.png')
        samples[-1].result.save(out/f'{name}_result.png')
        row = dict(name=name,mode=mode,source_fps=session.info.fps,size=list(samples[-1].source.size),
                   samples_checked=[pair.index for pair in samples],**stats)
        report['cases'].append(row)
        print(json.dumps(row),flush=True)
    # Verify every frame in a short sequential run, including a slow algorithm.
    short = ROOT/'tools/board_results_video/sequential.mp4'
    from generate_video_fixture import generate
    generate(short,seconds=0.4,fps=10,size=(320,240))
    session = VideoSession(short,realtime=False,mode=0).start()
    assert session.done.wait(5) and not session.error
    assert session.snapshot()['processed'] == 4 and session.snapshot()['skipped'] == 0
    report['sequential'] = session.snapshot()
    report['status'] = 'passed'
    (out/'video_acceptance.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')


if __name__ == '__main__':
    main()
