"""Real video decoding, exact pixel packing, playback control and UDP cancellation."""
import contextlib
import queue
import struct
import tempfile
import threading
import time
from pathlib import Path
import unittest
from unittest.mock import patch

import cv2
import numpy as np
from PIL import Image

from eth_image import UdpImageClient,TransferCancelled
from test_eth_transport import UdpResponder
from test_eth_window import WindowBoard
from uart_image import Packet,image_to_rgb565,rgb565_to_image
from video_pipeline import (PlaybackClock,VideoReader,VideoSession,fit_video_frame,
                            encode_rgb565,decode_rgb565)


class DummyClient:
    def __init__(self,*args,**kwargs):
        self.retry_count = 0
        self.closed = False

    def __enter__(self):
        return self

    def __exit__(self,*args):
        self.closed = True


def fake_processor(client,image,mode,threshold):
    time.sleep(0.025)
    return image,image.copy(),0.02,{}


class VideoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.path = Path(cls.temp.name)/'视频 控制.avi'
        writer = cv2.VideoWriter(str(cls.path),cv2.VideoWriter_fourcc(*'MJPG'),60,(64,48))
        assert writer.isOpened()
        for index in range(24):
            writer.write(np.full((48,64,3),index*9,dtype=np.uint8))
        writer.release()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_vectorized_codec_matches_all_rgb565_values(self):
        data = struct.pack('<65536H',*range(65536))
        image = decode_rgb565(data,256,256)
        self.assertEqual(image.tobytes(),rgb565_to_image(data,256,256).tobytes())
        self.assertEqual(encode_rgb565(image),data)

    def test_rgb888_encoder_matches_independent_scalar_with_odd_geometry(self):
        rng = np.random.default_rng(1949)
        image = Image.fromarray(rng.integers(0,256,(93,127,3),dtype=np.uint8))
        self.assertEqual(encode_rgb565(image),image_to_rgb565(image))
        with self.assertRaises(ValueError):
            decode_rgb565(b'\x00',1,1)

    def test_fit_preserves_aspect_ratio_and_requires_explicit_oversize_resize(self):
        self.assertEqual(fit_video_frame(Image.new('RGB',(1920,1080)),(320,240)).size,(320,180))
        self.assertEqual(fit_video_frame(Image.new('RGB',(1080,1920)),(320,240)).size,(135,240))
        self.assertEqual(fit_video_frame(Image.new('RGB',(17,19)),(640,360)).size,(17,19))
        with self.assertRaises(ValueError):
            fit_video_frame(Image.new('RGB',(1921,1080)),None)

    def test_clock_freezes_and_excludes_all_pause_time(self):
        now = [100.0]
        clock = PlaybackClock(now=lambda:now[0])
        now[0] = 101
        clock.pause()
        now[0] = 111
        self.assertEqual(clock.position(),1)
        clock.resume()
        now[0] = 112
        self.assertEqual(clock.position(),2)
        clock.pause()
        now[0] = 120
        clock.resume()
        self.assertEqual(clock.position(),2)

    def test_unicode_file_metadata_forward_skips_eof_and_release(self):
        with VideoReader(self.path) as reader:
            self.assertEqual((reader.info.width,reader.info.height,reader.info.frame_count),(64,48,24))
            first = reader.read_at(0)
            last = reader.read_at(23)
            self.assertLess(np.asarray(first).mean(),np.asarray(last).mean())
            self.assertIsNone(reader.read_at(24))
            with self.assertRaises(ValueError):
                reader.read_at(0)
        self.assertFalse(reader.capture.isOpened())
        with self.assertRaises(FileNotFoundError):
            VideoReader(self.path.with_name('missing.mp4'))

    def test_realtime_skips_old_frames_and_display_queue_is_bounded(self):
        session = VideoSession(self.path,processor=fake_processor,client_factory=DummyClient).start()
        self.assertTrue(session.done.wait(3))
        self.assertIsNone(session.error)
        stats = session.snapshot()
        self.assertGreater(stats['skipped'],0)
        self.assertEqual(stats['processed']+stats['skipped'],24)
        self.assertEqual(stats['last_index'],23)
        self.assertEqual(session.frames.qsize(),1)
        pair = session.take_latest()
        self.assertEqual(pair.index,23)
        self.assertEqual(pair.source.tobytes(),pair.result.tobytes())

    def test_sequential_processes_every_frame_exactly_once(self):
        observed = []
        def processor(*args):
            observed.append(1)
            return fake_processor(*args)
        session = VideoSession(self.path,realtime=False,processor=processor,client_factory=DummyClient).start()
        self.assertTrue(session.done.wait(3))
        self.assertEqual(session.snapshot()['processed'],24)
        self.assertEqual(session.snapshot()['skipped'],0)
        self.assertEqual(len(observed),24)

    def test_pause_resume_and_stop_release_worker(self):
        session = VideoSession(self.path,realtime=False,processor=fake_processor,client_factory=DummyClient).start()
        deadline = time.monotonic()+1
        while session.snapshot()['processed'] < 2 and time.monotonic() < deadline:
            time.sleep(0.005)
        session.pause()
        time.sleep(0.04)
        before = session.snapshot()['processed']
        time.sleep(0.08)
        self.assertEqual(session.snapshot()['processed'],before)
        session.resume()
        time.sleep(0.06)
        self.assertGreater(session.snapshot()['processed'],before)
        session.stop()
        self.assertTrue(session.done.wait(0.5))
        self.assertEqual(session.snapshot()['state'],'stopped')

    def test_worker_exception_is_reported_and_client_is_closed(self):
        clients = []
        def client(*args,**kwargs):
            value = DummyClient()
            clients.append(value)
            return value
        def broken(*args):
            raise RuntimeError('test decode/processing failure')
        session = VideoSession(self.path,processor=broken,client_factory=client).start()
        self.assertTrue(session.done.wait(1))
        self.assertIn('test decode/processing failure',session.error)
        self.assertEqual(session.snapshot()['state'],'failed')
        self.assertTrue(clients[0].closed)

    def test_gui_reads_final_snapshot_after_done_race(self):
        import tkinter as tk
        from types import SimpleNamespace
        from unittest.mock import Mock
        from eth_image_gui import ImageApp
        root = tk.Tk()
        root.attributes('-alpha',0.0)
        app = ImageApp(root)
        try:
            app.load_video(self.path)
            stats = dict(processed_fps=0.0,last_frame_seconds=0.0,skipped=0,retries=0,
                         position_seconds=0.0,last_index=-1,processed=0,state='playing')
            snapshot = Mock(side_effect=[stats,{**stats,'state':'stopped'}])
            app.video_session = SimpleNamespace(take_latest=lambda:None,snapshot=snapshot,
                info=app.video_info,clock=SimpleNamespace(paused=False),
                done=SimpleNamespace(is_set=lambda:True),error=None)
            app.set_busy(True)
            app._poll_video()
            self.assertEqual(snapshot.call_count,2)
            self.assertEqual(app.last_video_stats['state'],'stopped')
            self.assertIsNone(app.video_session)
            self.assertFalse(app.busy)
        finally:
            root.destroy()

    def test_gui_pause_stop_viewport_and_switch_back_to_image(self):
        import tkinter as tk
        from eth_image_gui import ImageApp
        root = tk.Tk()
        root.attributes('-alpha',0.0)
        app = ImageApp(root)
        try:
            app.mode.set('原图回传')
            app.load_video(self.path)
            factory = lambda *args,**kwargs: VideoSession(*args,**kwargs,client_factory=DummyClient,processor=fake_processor)
            with patch('video_pipeline.VideoSession',side_effect=factory):
                app.start_video()
            deadline = time.monotonic()+2
            while app.last_video_pair is None and time.monotonic() < deadline:
                root.update()
                time.sleep(0.005)
            self.assertIsNotNone(app.last_video_pair)
            app.pause_video()
            app.left_image.zoom(3)
            root.update()
            scale = app.left_image.scale
            index = app.last_video_pair.index
            for _ in range(15):
                root.update()
                time.sleep(0.005)
            self.assertEqual(app.last_video_pair.index,index)
            app.pause_video()
            for _ in range(15):
                root.update()
                time.sleep(0.005)
            self.assertEqual(app.left_image.scale,scale)
            app.stop_video()
            deadline = time.monotonic()+1
            while app.busy and time.monotonic() < deadline:
                root.update()
                time.sleep(0.005)
            self.assertFalse(app.busy)
            self.assertEqual(app.last_video_stats['state'],'stopped')
            path = Path(self.temp.name)/'still.png'
            Image.new('RGB',(17,19)).save(path)
            app.load_image(path)
            self.assertIsNone(app.video_path)
            self.assertEqual(app.dimensions(),(17,19))
        finally:
            if app.video_session:
                app.video_session.stop()
                app.video_session.done.wait(1)
            for callback in root.tk.call('after','info'):
                root.after_cancel(callback)
            root.destroy()


class VideoCancellationTests(unittest.TestCase):
    def run_cancel(self,window):
        cancel = threading.Event()
        seen = threading.Event()
        board = WindowBoard(bytes(8192),64,64)
        def handle(data,count):
            if window and data[5] == 3:
                seen.set()
                return []
            if not window:
                seen.set()
                return []
            return board.handle(data,count)
        server = UdpResponder(handle)
        self.addCleanup(server.close)
        client = UdpImageClient(*server.peer,timeout=5,cancel_event=cancel)
        self.addCleanup(client.close)
        errors = []
        def work():
            try:
                client.transfer(bytes(8192),64,64,0) if window else client.transact(Packet(1),8,timeout=5)
            except BaseException as exc:
                errors.append(exc)
        thread = threading.Thread(target=work)
        thread.start()
        self.assertTrue(seen.wait(1))
        start = time.monotonic()
        cancel.set()
        thread.join(0.5)
        self.assertFalse(thread.is_alive())
        self.assertLess(time.monotonic()-start,0.3)
        self.assertIsInstance(errors[0],TransferCancelled)
        self.assertEqual(client.retry_count,0)

    def test_stop_during_single_request_wait(self):
        self.run_cancel(False)

    def test_stop_during_window_reply_wait(self):
        self.run_cancel(True)


if __name__ == '__main__':
    unittest.main()
