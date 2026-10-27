"""Bounded video-file playback: PC decoding, FPGA processing, paired results."""
from __future__ import annotations

from dataclasses import dataclass, field
import math
from pathlib import Path
import queue
import threading
import time

import cv2
from PIL import Image

from rgb565_codec import encode_rgb565,decode_rgb565
from eth_image import UdpImageClient, TransferCancelled, DEFAULT_HOST, DEFAULT_PORT
from hog_client import HOGClient, prepare_hog, draw_detections
from hog_model import THRESHOLD
from uart_image import MAX_WIDTH, MAX_HEIGHT, ProtocolError

VIDEO_SIZES = {
    '320×240': (320,240), '640×360': (640,360), '640×480': (640,480),
    '1280×720': (1280,720), '1920×1080': (1920,1080), '原视频尺寸': None,
}


@dataclass(frozen=True)
class VideoInfo:
    path: Path
    width: int
    height: int
    fps: float
    frame_count: int

    @property
    def duration(self):
        return self.frame_count/self.fps


@dataclass
class FramePair:
    index: int
    timestamp: float
    source: Image.Image
    result: Image.Image
    network_seconds: float
    frame_seconds: float
    details: dict = field(default_factory=dict)


class VideoReader:
    def __init__(self, path, *, stop_event=None):
        self.path = Path(path).resolve()
        if not self.path.is_file():
            raise FileNotFoundError(f'找不到视频：{self.path.name}')
        self.capture = cv2.VideoCapture(str(self.path), cv2.CAP_FFMPEG)
        self.stop_event = stop_event
        self.next_index = 0
        try:
            if not self.capture.isOpened():
                raise ValueError('无法解码该视频，请使用常见编码的 MP4、AVI、MOV 或 MKV 文件')
            width = int(self.capture.get(cv2.CAP_PROP_FRAME_WIDTH))
            height = int(self.capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
            fps = float(self.capture.get(cv2.CAP_PROP_FPS))
            count = max(0,int(self.capture.get(cv2.CAP_PROP_FRAME_COUNT)))
            if width < 1 or height < 1 or not math.isfinite(fps) or not 0 < fps <= 1000:
                raise ValueError('视频尺寸或帧率无效')
            self.info = VideoInfo(self.path,width,height,fps,count)
        except BaseException:
            self.capture.release()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.capture.release()

    def read_at(self, index):
        if index < self.next_index:
            raise ValueError('视频读取只允许向前；重新播放请重新打开文件')
        while self.next_index < index:
            self._check_stop()
            if not self.capture.grab():
                return None
            self.next_index += 1
        self._check_stop()
        ok, bgr = self.capture.read()
        if not ok:
            return None
        self.next_index += 1
        return Image.fromarray(cv2.cvtColor(bgr,cv2.COLOR_BGR2RGB))

    def _check_stop(self):
        if self.stop_event is not None and self.stop_event.is_set():
            raise TransferCancelled('已停止视频解码')


def fit_video_frame(image, bounds):
    width,height = image.size
    if bounds is None:
        if not 1 <= width <= MAX_WIDTH or not 1 <= height <= MAX_HEIGHT:
            raise ValueError('原视频超过 1920×1080，请选择视频处理尺寸')
        return image.convert('RGB')
    bw,bh = bounds
    if not 1 <= bw <= MAX_WIDTH or not 1 <= bh <= MAX_HEIGHT:
        raise ValueError('视频处理尺寸超出 FPGA 范围')
    scale = min(1.0,bw/width,bh/height)
    size = (max(1,min(bw,round(width*scale))),max(1,min(bh,round(height*scale))))
    rgb = image.convert('RGB')
    return rgb if rgb.size == size else rgb.resize(size,Image.Resampling.BILINEAR)


def process_video_frame(client, image, mode, threshold):
    if mode == 5:
        from stream_sobel import PreparedSobelFrame,prepare_sobel_frame,decode_gray8
        prepared = image if isinstance(image,PreparedSobelFrame) else prepare_sobel_frame(image)
        width,height = prepared.source.size
        start = time.perf_counter()
        result = client.transfer_sobel_stream(prepared.padded,width,height,padded=True)
        network = time.perf_counter()-start
        return prepared.source,decode_gray8(result,width,height),network,dict(
            transport='stream_sobel_gray8',backend=getattr(client,'stream_backend','python'),upload_bytes=len(prepared.padded),result_bytes=len(result))
    if mode == 8:
        gray,geometry = prepare_hog(image)
        start = time.perf_counter()
        scores = HOGClient(client).detect(gray)
        network_seconds = time.perf_counter()-start
        result,boxes = draw_detections(image,scores,geometry,threshold)
        return image,result,network_seconds,dict(scores=scores,geometry=geometry,boxes=len(boxes))
    if not 0 <= mode <= 7:
        raise ValueError('视频支持图像算法和 HOG 行人检测；Band 请使用图片模式')
    raw = encode_rgb565(image)
    start = time.perf_counter()
    received = client.transfer(raw,*image.size,mode)
    network_seconds = time.perf_counter()-start
    if len(received) != len(raw) or (mode == 0 and received != raw):
        raise ProtocolError('视频帧回传校验失败')
    return decode_rgb565(raw,*image.size),decode_rgb565(received,*image.size),network_seconds,{}


class PlaybackClock:
    def __init__(self, *, now=time.monotonic):
        self.now = now
        self.condition = threading.Condition()
        self.origin = now()
        self.paused_at = None
        self.paused_seconds = 0.0

    def _time(self):
        return (self.paused_at if self.paused_at is not None else self.now())-self.origin-self.paused_seconds

    def position(self):
        with self.condition:
            return self._time()

    @property
    def paused(self):
        with self.condition:
            return self.paused_at is not None

    def pause(self):
        with self.condition:
            if self.paused_at is None:
                self.paused_at = self.now()
            self.condition.notify_all()

    def resume(self):
        with self.condition:
            if self.paused_at is not None:
                self.paused_seconds += self.now()-self.paused_at
                self.paused_at = None
            self.condition.notify_all()

    def wait_until(self, target, stop):
        with self.condition:
            while not stop.is_set():
                if self.paused_at is not None:
                    self.condition.wait(0.05)
                    continue
                remaining = target-self._time()
                if remaining <= 0:
                    return True
                self.condition.wait(min(0.05,remaining))
            return False

    def wake(self):
        with self.condition:
            self.condition.notify_all()


class VideoSession:
    def __init__(self, path, *, host=DEFAULT_HOST, port=DEFAULT_PORT, bind_ip='', mode=0,
                 bounds=(640,360), realtime=True, threshold=THRESHOLD,
                 client_factory=UdpImageClient, reader_factory=VideoReader,
                 processor=process_video_frame):
        if mode not in range(9):
            raise ValueError('视频模式请选择图像算法或 HOG')
        self.path = Path(path)
        self.host,self.port,self.mode = host,port,mode
        self.bind_ip = bind_ip
        self.bounds,self.realtime,self.threshold = bounds,realtime,threshold
        self.client_factory,self.reader_factory,self.processor = client_factory,reader_factory,processor
        self.stop_event = threading.Event()
        self.done = threading.Event()
        self.frames = queue.Queue(maxsize=1)
        self.clock = PlaybackClock()
        self.lock = threading.Lock()
        self.thread = None
        self.info = None
        self.error = None
        self.stats = dict(processed=0,skipped=0,retries=0,position_seconds=0.0,
                          elapsed_seconds=0.0,processed_fps=0.0,last_network_seconds=0.0,
                          last_frame_seconds=0.0,last_index=-1,state='ready')

    def start(self):
        if self.thread is not None:
            raise RuntimeError('视频会话不能重复启动')
        self.thread = threading.Thread(target=self._run,daemon=True,name='fpga-video')
        self.thread.start()
        return self

    def pause(self):
        self.clock.pause()

    def resume(self):
        self.clock.resume()

    def stop(self):
        self.stop_event.set()
        self.clock.wake()

    def snapshot(self):
        with self.lock:
            value = dict(self.stats)
        value['paused'] = self.clock.paused
        return value

    def take_latest(self):
        try:
            return self.frames.get_nowait()
        except queue.Empty:
            return None

    def _publish(self, pair):
        try:
            self.frames.put_nowait(pair)
        except queue.Full:
            try:
                self.frames.get_nowait()
            except queue.Empty:
                pass
            self.frames.put_nowait(pair)

    def _run(self):
        if self.mode == 5 and self.processor is process_video_frame:
            return self._run_stream_sobel()
        client = None
        try:
            with self.reader_factory(self.path,stop_event=self.stop_event) as reader:
                self.info = reader.info
                with self.client_factory(self.host,self.port,bind_ip=self.bind_ip,cancel_event=self.stop_event) as client:
                    index = -1
                    processed = 0
                    with self.lock:
                        self.stats['state'] = 'playing'
                    while self.clock.wait_until(0,self.stop_event):
                        target = index+1
                        if self.realtime and index >= 0:
                            target = max(target,int(self.clock.position()*self.info.fps))
                        if self.info.frame_count:
                            target = min(target,self.info.frame_count-1)
                            if target <= index:
                                break
                        if not self.clock.wait_until(target/self.info.fps,self.stop_event):
                            break
                        image = reader.read_at(target)
                        if image is None:
                            break
                        start = time.perf_counter()
                        image = fit_video_frame(image,self.bounds)
                        left,right,network,details = self.processor(client,image,self.mode,self.threshold)
                        frame_seconds = time.perf_counter()-start
                        if not self.clock.wait_until(0,self.stop_event):
                            break
                        pair = FramePair(target,target/self.info.fps,left,right,network,frame_seconds,details)
                        processed += 1
                        index = target
                        elapsed = self.clock.position()
                        with self.lock:
                            self.stats.update(processed=processed,skipped=index+1-processed,
                                              retries=client.retry_count,last_index=index,
                                              position_seconds=pair.timestamp,elapsed_seconds=elapsed,
                                              processed_fps=processed/max(elapsed,0.000001),
                                              last_network_seconds=network,last_frame_seconds=frame_seconds)
                        self._publish(pair)
        except TransferCancelled:
            pass
        except Exception as exc:
            self.error = str(exc)
        finally:
            with self.lock:
                if client is not None:
                    self.stats['retries'] = client.retry_count
                self.stats['state'] = 'failed' if self.error else ('stopped' if self.stop_event.is_set() else 'finished')
            self.done.set()

    def _run_stream_sobel(self):
        """A bounded decoder/packer overlaps the network worker; Tk stays on its thread."""
        from stream_sobel import prepare_sobel_frame
        prepared_frames = queue.Queue(maxsize=2)
        producer_done = threading.Event()
        producer_errors = []
        producer = None
        client = None
        # A local event also shuts down a blocked producer after a network error.
        producer_stop = threading.Event()
        def put_frame(value):
            while not producer_stop.is_set() and not self.stop_event.is_set():
                try:
                    prepared_frames.put(value,timeout=0.02)
                    return True
                except queue.Full:
                    pass
            return False
        try:
            with self.reader_factory(self.path,stop_event=self.stop_event) as reader:
                self.info = reader.info
                def prepare():
                    try:
                        index = 0
                        while not producer_stop.is_set() and not self.stop_event.is_set():
                            if self.info.frame_count and index >= self.info.frame_count:
                                break
                            if self.realtime and index:
                                index = max(index,int(self.clock.position()*self.info.fps))
                                if self.info.frame_count:
                                    index = min(index,self.info.frame_count-1)
                            image = reader.read_at(index)
                            if image is None:
                                break
                            started = time.perf_counter()
                            frame = prepare_sobel_frame(fit_video_frame(image,self.bounds))
                            if not put_frame((index,frame,time.perf_counter()-started)):
                                break
                            index += 1
                    except Exception as exc:
                        producer_errors.append(exc)
                    finally:
                        producer_done.set()
                producer = threading.Thread(target=prepare,daemon=True,name='fpga-video-prepare')
                producer.start()
                try:
                    with self.client_factory(self.host,self.port,bind_ip=self.bind_ip,cancel_event=self.stop_event,window_size=64) as client:
                        processed = 0
                        with self.lock:
                            self.stats['state'] = 'playing'
                        while self.clock.wait_until(0,self.stop_event):
                            try:
                                index,frame,prepare_seconds = prepared_frames.get(timeout=0.02)
                            except queue.Empty:
                                if producer_done.is_set():
                                    break
                                continue
                            if not self.clock.wait_until(index/self.info.fps,self.stop_event):
                                break
                            start = time.perf_counter()
                            left,right,network,details = self.processor(client,frame,self.mode,self.threshold)
                            details['prepare_seconds'] = prepare_seconds
                            frame_seconds = time.perf_counter()-start
                            if not self.clock.wait_until(0,self.stop_event):
                                break
                            pair = FramePair(index,index/self.info.fps,left,right,network,frame_seconds,details)
                            processed += 1
                            elapsed = self.clock.position()
                            with self.lock:
                                self.stats.update(processed=processed,skipped=index+1-processed,
                                    retries=client.retry_count,last_index=index,position_seconds=pair.timestamp,
                                    elapsed_seconds=elapsed,processed_fps=processed/max(elapsed,0.000001),
                                    last_network_seconds=network,last_frame_seconds=frame_seconds)
                            self._publish(pair)
                    if producer_errors:
                        raise producer_errors[0]
                finally:
                    producer_stop.set()
                    producer.join(timeout=2)
                    if producer.is_alive():
                        raise RuntimeError('视频准备线程未按时退出')
        except TransferCancelled:
            pass
        except Exception as exc:
            self.error = str(exc)
        finally:
            producer_stop.set()
            with self.lock:
                if client is not None:
                    self.stats['retries'] = client.retry_count
                self.stats['state'] = 'failed' if self.error else ('stopped' if self.stop_event.is_set() else 'finished')
            self.done.set()
