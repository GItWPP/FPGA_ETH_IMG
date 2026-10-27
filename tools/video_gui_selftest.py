"""Exercise real GUI video controls against the FPGA, including frozen FFmpeg."""
import json
from pathlib import Path
import sys
import time
import tkinter as tk
from unittest.mock import patch

from hog_client import HOG_LABEL


def run(report_path,host,port,input_path,mode,*,snapshot=None):
    from eth_image_gui import ImageApp
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True,exist_ok=True)
    report = dict(status='running',frozen=bool(getattr(sys,'frozen',False)),mode=mode,input=str(input_path))
    root = tk.Tk()
    root.attributes('-alpha',0.0)
    app = ImageApp(root)
    errors = []
    try:
        app.host.set(host)
        app.udp_port.set(str(port))
        app.mode.set('Sobel 边缘检测' if mode == 'video_sobel25' else (HOG_LABEL if mode == 'video_hog' else '原图回传'))
        app.video_size.set('原视频尺寸' if mode == 'video_sobel25' else '320×240')
        if mode == 'video_sobel25':
            app.video_policy.set('逐帧处理（不跳帧）')
        app.load_video(input_path)
        root.update()
        with patch('eth_image_gui.messagebox.showerror',side_effect=lambda *args:errors.append(args)):
            app.start_video()
            stage = 'wait_frame'
            deadline = time.monotonic()+15
            while app.busy and time.monotonic() < deadline:
                root.update()
                pair = app.last_video_pair
                now = time.monotonic()
                if pair is not None and stage == 'wait_frame':
                    app.left_image.actual_size()
                    app.left_image.zoom(3)
                    scale = app.left_image.scale
                    app.pause_video()
                    paused_index = pair.index
                    pause_time = now
                    stage = 'paused'
                elif stage == 'paused' and now-pause_time >= 0.16:
                    assert app.last_video_pair.index == paused_index,'Display advanced while paused'
                    app.pause_video()
                    stage = 'resumed'
                elif stage == 'resumed' and pair.index != paused_index:
                    assert app.left_image.scale == scale,'Video reset manual zoom'
                    app.stop_video()
                    stage = 'stopping'
                time.sleep(0.004)
            assert not app.busy and not errors,(app.status.get(),errors)
            assert app.last_video_stats['state'] == 'stopped',app.last_video_stats
            report['pause_resume_stop'] = 'passed'
            app.left_image.fit_image()
            app.start_video()
            deadline = time.monotonic()+60
            while app.busy and time.monotonic() < deadline:
                root.update()
                time.sleep(0.004)
        assert not app.busy and not errors,(app.status.get(),errors)
        stats = app.last_video_stats
        assert stats['state'] == 'finished' and stats['processed'] > 0,stats
        assert stats['processed']+stats['skipped'] == stats['source_frames'],stats
        pair = app.last_video_pair
        assert pair.index == stats['source_frames']-1,'GUI omitted final frame'
        if mode == 'video_copy':
            assert pair.source.tobytes() == pair.result.tobytes(),'GUI paired different frames'
        elif mode == 'video_sobel25':
            from stream_sobel_reference import reference_gray8
            from rgb565_codec import encode_rgb565
            assert pair.source.size == (1280,720)
            assert abs(stats['source_fps']-25)<0.01
            assert stats['skipped']==0 and stats['retries']==0 and stats['processed_fps']>=24.8,stats
            assert pair.result.convert('L').tobytes()==reference_gray8(encode_rgb565(pair.source),*pair.source.size)
        else:
            from hog_client import prepare_hog
            from hog_reference import detect_reference
            gray,_ = prepare_hog(pair.source)
            assert detect_reference(gray) == pair.details['scores'],'Frozen video HOG mismatch'
        pair.result.save(report_path.with_suffix('.png'))
        app.right_image.fit_image()
        root.update()
        if snapshot:
            from PIL import ImageGrab
            snapshot = Path(snapshot)
            snapshot.parent.mkdir(parents=True,exist_ok=True)
            ImageGrab.grab(window=int(root.wm_frame(),0)).save(snapshot)
            report['snapshot'] = str(snapshot)
        report.update(status='passed',gui_status=app.status.get(),stats=stats,frame_size=list(pair.source.size))
    except Exception as exc:
        report.update(status='failed',error=repr(exc),dialogs=errors)
    finally:
        if app.video_session is not None:
            app.video_session.stop()
            app.video_session.done.wait(2)
        for callback in root.tk.call('after','info'):
            root.after_cancel(callback)
        root.destroy()
        report_path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    return 0 if report['status'] == 'passed' else 1
