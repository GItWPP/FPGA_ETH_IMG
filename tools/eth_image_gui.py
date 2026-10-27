"""FPGA image workbench with collapsible settings and interactive image views."""
from __future__ import annotations

from pathlib import Path
import argparse
import math
import ipaddress
import queue
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from PIL import Image
from image_viewer import COLORS, ImageViewer
from uart_image import ( MODE_LABELS, MAX_WIDTH, MAX_HEIGHT,
                        reference,
                        load_source_image, prepare_image)
from rgb565_codec import encode_rgb565 as image_to_rgb565, decode_rgb565 as rgb565_to_image
from eth_image import UdpImageClient, DEFAULT_HOST, DEFAULT_PORT, network_endpoint
from hog_client import HOGClient, HOG_LABEL, prepare_hog, draw_detections
from hog_reference import detect_reference
from hog_model import THRESHOLD, SCORE_SHIFT, MODEL_ID
from band_client import BAND_LABEL, BandClient, prepare_band, draw_band, export_band

MODE_LABELS = {**MODE_LABELS, HOG_LABEL: 8, BAND_LABEL: 9}


class ImageApp:
    def __init__(self, root):
        self.root = root
        self.events = queue.Queue()
        self.source = self.result = None
        self.band_result = None
        self.binary_window = None
        self.busy = False
        self._preview_key = None
        self._settings_visible = True
        self.host = tk.StringVar(value=DEFAULT_HOST)
        self.udp_port = tk.StringVar(value=str(DEFAULT_PORT))
        self.bind_ip = tk.StringVar(value='自动选择')
        self.auto_size = tk.BooleanVar(value=True)
        self.width,self.height = tk.StringVar(),tk.StringVar()
        self.mode = tk.StringVar(value='Gamma 暗部提亮')
        self.hog_threshold = tk.StringVar(value=f'{THRESHOLD / (1 << SCORE_SHIFT):.4f}')
        self.status = tk.StringVar(value='打开图片或视频，选择算法后发送到 FPGA。')
        self.path_text = tk.StringVar(value='尚未选择文件')
        self.connection_text = tk.StringVar()
        self.percent_text = tk.StringVar(value='就绪')
        self.video_path = self.video_info = self.video_session = None
        self.video_preview_source = None
        self.last_video_stats = self.last_video_pair = None
        self._close_after_video = False
        self.video_size = tk.StringVar(value='640×360')
        self.video_policy = tk.StringVar(value='实时播放（跳帧）')
        self.video_time = tk.StringVar(value='00:00.0 / 00:00.0')
        from workbench_layout import build_workbench
        build_workbench(self,MODE_LABELS)
        for variable in (self.host,self.udp_port,self.width,self.height,self.bind_ip):
            variable.trace_add('write',lambda *args: self.update_summary())
        root.bind('<Control-o>',lambda event: self.open_image())
        root.bind('<Control-s>',lambda event: self.save())
        root.bind('<Control-Return>',lambda event: self.send())
        root.protocol('WM_DELETE_WINDOW',self.close)
        self.update_summary()
        self._poll_job = root.after(60,self.poll)

    def bind_ip_value(self):
        value = self.bind_ip.get()
        return '' if value == '自动选择' else str(ipaddress.IPv4Address(value))

    @staticmethod
    def format_time(seconds):
        return f'{int(seconds)//60:02d}:{seconds%60:04.1f}'

    def open_video(self):
        if self.busy:
            return
        path = filedialog.askopenfilename(filetypes=[('视频','*.mp4 *.avi *.mov *.mkv *.m4v *.wmv'),('所有文件','*.*')])
        if path:
            try:
                self.load_video(path)
            except ImportError:
                messagebox.showerror('视频组件','请使用新版 EXE，源码运行需安装 tools/requirements-video.txt')
            except Exception as exc:
                messagebox.showerror('无法加载视频',str(exc))

    def load_video(self, path):
        if self.busy:
            raise RuntimeError('请先停止当前任务')
        from video_pipeline import VideoReader
        with VideoReader(path) as reader:
            first = reader.read_at(0)
            if first is None:
                raise ValueError('视频没有可解码的帧')
            info = reader.info
        self.video_path,self.video_info = Path(path).resolve(),info
        self.left_image.allow_upscale = self.right_image.allow_upscale = True
        self.source = self.video_preview_source = first
        self.last_video_stats = self.last_video_pair = None
        self.path_text.set(f'{self.video_path.name}\n{info.width}×{info.height} · {info.fps:.2f} FPS')
        self.mode_combo.configure(values=tuple(label for label in MODE_LABELS if label != BAND_LABEL))
        if self.mode.get() == BAND_LABEL:
            self.mode.set(HOG_LABEL)
        self.video_bar.pack(fill='x',pady=(0,12),before=self.display_controls)
        self.video_time.set(f'00:00.0 / {self.format_time(info.duration)}')
        self.metric_values['source_fps'].set(f'{info.fps:.2f}')
        for key in ('fps','mbps','latency','skipped','retries'):
            self.metric_values[key].set('—')
        self.progress['value'] = 0
        self.percent_text.set('视频就绪')
        self.set_busy(False)
        self.send_button.configure(text='开始播放')
        self.update_video_preview()

    def update_video_preview(self):
        if self.video_path is None or self.busy:
            return
        from video_pipeline import VIDEO_SIZES,fit_video_frame,encode_rgb565,decode_rgb565
        try:
            image = fit_video_frame(self.video_preview_source,VIDEO_SIZES[self.video_size.get()])
            if MODE_LABELS[self.mode.get()] != 8:
                image = decode_rgb565(encode_rgb565(image),*image.size)
            self.width.set(str(image.width))
            self.height.set(str(image.height))
            self.left_image.set_image(image)
            self.clear_result('开始播放后显示 FPGA 视频处理结果')
            self.status.set(f'视频 {self.video_info.width}×{self.video_info.height} · {self.video_info.fps:.2f} FPS · 处理尺寸 {image.width}×{image.height}')
        except ValueError as exc:
            self.status.set(str(exc))
        self.binary_button.grid_remove()
        self.save_button.configure(text='保存当前帧')
        self.save_button.grid_configure(columnspan=2)
        self.size_hint.configure(text='视频尺寸在下方播放区域中设置，等比例缩放')
        self.band_note.grid_remove()
        for widget in (self.hog_label,self.hog_threshold_entry,self.hog_note):
            widget.grid() if self.mode.get() == HOG_LABEL else widget.grid_remove()

    def start_video(self):
        if self.busy or self.video_path is None:
            return
        try:
            from video_pipeline import VideoSession,VIDEO_SIZES,fit_video_frame
            host,port = network_endpoint(self.host.get(),self.udp_port.get())
            bind_ip = self.bind_ip_value()
            threshold = float(self.hog_threshold.get())
            if not math.isfinite(threshold) or abs(threshold) > 100:
                raise ValueError('HOG 阈值请输入 -100 到 100 的有限数值')
            bounds = VIDEO_SIZES[self.video_size.get()]
            fit_video_frame(self.video_preview_source,bounds)
            session = VideoSession(self.video_path,host=host,port=port,bind_ip=bind_ip,
                                   mode=MODE_LABELS[self.mode.get()],bounds=bounds,
                                   realtime=self.video_policy.get().startswith('实时'),
                                   threshold=round(threshold*(1 << SCORE_SHIFT)))
        except Exception as exc:
            messagebox.showerror('视频设置',str(exc))
            return
        self.last_video_stats = self.last_video_pair = None
        self.video_session = session
        self.clear_result('等待第一帧 FPGA 处理结果…')
        self.progress['value'] = 0
        self.percent_text.set('播放中')
        self.status.set('正在解码视频并连接 FPGA…')
        self.video_pause_button.configure(text='暂停')
        self.set_busy(True)
        session.start()

    def pause_video(self):
        if self.video_session is None:
            return
        if self.video_session.clock.paused:
            self.video_session.resume()
            self.video_pause_button.configure(text='暂停')
        else:
            self.video_session.pause()
            self.video_pause_button.configure(text='继续')

    def stop_video(self):
        if self.video_session is not None:
            self.video_session.stop()
            self.video_pause_button.configure(state='disabled')
            self.video_stop_button.configure(state='disabled')
            self.status.set('正在停止视频传输…')

    def _poll_video(self):
        session = self.video_session
        if session is None:
            return False
        if not session.clock.paused or session.done.is_set():
            pair = session.take_latest()
            if pair is not None:
                self.last_video_pair = pair
                self.result = pair.result
                self.left_image.update_image(pair.source)
                self.right_image.update_image(pair.result)
                self.save_button.configure(state='normal')
        stats = session.snapshot()
        self.metric_values['fps'].set(f'{stats["processed_fps"]:.2f}')
        self.metric_values['latency'].set(f'{stats["last_frame_seconds"]*1000:.1f}')
        self.metric_values['skipped'].set(str(stats['skipped']))
        self.metric_values['retries'].set(str(stats['retries']))
        if self.last_video_pair is not None:
            pair = self.last_video_pair
            if MODE_LABELS[self.mode.get()] < 8:
                self.metric_values['mbps'].set(f'{pair.source.width*pair.source.height*16/max(pair.network_seconds,1e-6)/1e6:.2f}')
            else:
                self.metric_values['mbps'].set('—')
        info = session.info or self.video_info
        self.video_time.set(f'{self.format_time(stats["position_seconds"])} / {self.format_time(info.duration)}')
        if info.duration:
            self.progress['value'] = min(100,(stats['last_index']+1)/max(1,info.frame_count)*100)
        paused = session.clock.paused
        self.percent_text.set('已暂停' if paused else '播放中')
        self.status.set(f'{"已暂停" if paused else "视频处理"} · {self.mode.get()} · 第 {stats["last_index"]+1} 帧 · {stats["processed_fps"]:.2f} FPS · 跳过 {stats["skipped"]} 帧 · 重试 {stats["retries"]} 次')
        if not session.done.is_set():
            return False
        # The worker may finish between the first snapshot and the done check.
        # Once done is observed, read its final state before updating the UI.
        stats = session.snapshot()
        self.last_video_stats = {**stats,'source_fps':info.fps,'source_frames':info.frame_count,
                                 'mode':self.mode.get(),'input':str(self.video_path)}
        self.video_session = None
        self.set_busy(False)
        self.video_pause_button.configure(text='暂停')
        self.send_button.configure(text='重新播放')
        state = {'finished':'播放完成','stopped':'已停止','failed':'处理失败'}[stats['state']]
        self.percent_text.set(state)
        if stats['state'] == 'finished':
            self.progress['value'] = 100
        self.status.set(f'{state} · 已处理 {stats["processed"]} 帧 · {stats["processed_fps"]:.2f} FPS · 跳过 {stats["skipped"]} 帧 · 重试 {stats["retries"]} 次')
        if self._close_after_video:
            self.root.destroy()
            return True
        if session.error:
            messagebox.showerror('视频处理失败',session.error)
        return False

    def toggle_settings(self):
        self._settings_visible = not self._settings_visible
        if self._settings_visible:
            self.settings_panel.grid()
        else:
            self.settings_panel.grid_remove()
        self.settings_button.configure(text="隐藏控制" if self._settings_visible else "显示控制")

    def update_summary(self):
        sizing = f'视频 {self.width.get()}×{self.height.get()}' if self.video_path else (
            "自动尺寸" if self.auto_size.get() else f"{self.width.get()} × {self.height.get()}")
        self.connection_text.set(f"{self.host.get()}:{self.udp_port.get()}  ·  UDP  ·  {sizing}")

    def refresh(self):
        self.update_summary()

    def test_connection(self):
        if self.busy:
            return
        try:
            host, udp_port = network_endpoint(self.host.get(), self.udp_port.get())
            bind_ip = self.bind_ip_value()
        except ValueError as exc:
            messagebox.showerror("网络设置", str(exc))
            return
        self.set_busy(True)
        self.status.set("正在检测 ZU4EV UDP 连接…")
        def worker():
            try:
                with UdpImageClient(host, udp_port, bind_ip=bind_ip) as client:
                    client.ping()
                self.events.put(("connection", f"已连接 ZU4EV · {host}:{udp_port} · UDP"))
            except Exception as exc:
                self.events.put(("error", str(exc)))
        threading.Thread(target=worker, daemon=True).start()

    def dimensions(self):
        if self.auto_size.get():
            if self.source is None:
                raise ValueError("请先打开图片")
            width, height = self.source.size
            self.width.set(str(width))
            self.height.set(str(height))
        else:
            width, height = int(self.width.get()), int(self.height.get())
        if not (1 <= width <= MAX_WIDTH and 1 <= height <= MAX_HEIGHT):
            raise ValueError(f"图片尺寸为 {width}×{height}，支持宽度 1..{MAX_WIDTH}、高度 1..{MAX_HEIGHT}；可选择手动缩放")
        return width, height

    def select_preset(self, event=None):
        selection = self.size_preset.get()
        self.auto_size.set(selection == "自动识别原图")
        if self.auto_size.get():
            self.sync_native_dimensions()
        elif selection != "手动输入":
            width, height = selection.split("×")
            self.width.set(width)
            self.height.set(height)
        elif not self.width.get() or not self.height.get():
            self.width.set("128")
            self.height.set("128")
        self.update_size_controls()
        self.update_summary()
        self.update_source_preview()

    def sync_native_dimensions(self):
        self.width.set(str(self.source.width) if self.source is not None else "")
        self.height.set(str(self.source.height) if self.source is not None else "")

    def update_size_controls(self):
        state = "disabled" if self.busy or self.video_path else ("readonly" if self.auto_size.get() else "normal")
        self.width_entry.configure(state=state)
        self.height_entry.configure(state=state)

    def clear_result(self, message="发送并处理后，在这里查看结果"):
        if self.binary_window is not None and self.binary_window.winfo_exists():
            self.binary_window.destroy()
            self.binary_window = None
        self.result = None
        self.band_result = None
        self.binary_button.configure(state="disabled")
        self.save_button.configure(state="disabled")
        self.right_image.clear(message)

    def update_source_preview(self):
        if self.video_path is not None:
            self.update_video_preview()
            return
        band_mode = self.mode.get() == BAND_LABEL
        self.size_hint.configure(text="Band：16～512 × 16～512 · GRAY8" if band_mode else f"最大 {MAX_WIDTH} × {MAX_HEIGHT} · RGB565")
        for widget in (self.hog_label, self.hog_threshold_entry, self.hog_note):
            widget.grid_remove() if band_mode else widget.grid()
        self.band_note.grid() if band_mode else self.band_note.grid_remove()
        if band_mode:
            self.binary_button.grid()
        else:
            self.binary_button.grid_remove()
        self.save_button.configure(text="导出结果" if band_mode else "保存结果")
        self.save_button.grid_configure(columnspan=1 if band_mode else 2)
        if self.source is None:
            return
        try:
            width, height = self.dimensions()
            image = prepare_image(self.source, width, height)
            message = f"已读取 {self.source.width}×{self.source.height}，将发送 {width}×{height}"
            if self.auto_size.get():
                message += " · 自动原图尺寸"
            hog_mode = self.mode.get() == HOG_LABEL
            if hog_mode:
                message = f"原图 {width}×{height} · 检测时等比例补边至 320×240 · 64×128 单尺度窗口"
            elif band_mode:
                prepare_band(image)
                image = image.convert('L')
                message = f"Band · 原生 {width}×{height} 灰度图 · FPGA 自动定位与解码 · 底部两行同步点排除"
        except ValueError as exc:
            image = self.source
            width, height = image.size
            message = str(exc)
        hog_mode = self.mode.get() == HOG_LABEL
        key = (id(self.source), width, height, hog_mode, band_mode)
        if key != self._preview_key:
            # Pillow's C-level lookup preserves the exact RGB565 preview colors.
            red_blue = [((value >> 3) << 3) | (value >> 5) for value in range(256)]
            green = [((value >> 2) << 2) | (value >> 6) for value in range(256)]
            self.left_image.set_image(image if hog_mode or band_mode else image.point(red_blue + green + red_blue))
            self._preview_key = key
            self.clear_result()
        self.status.set(message)

    def use_original_size(self):
        if self.busy:
            return
        if self.source is None:
            messagebox.showinfo("提示", "请先打开图片。")
            return
        self.size_preset.set("自动识别原图")
        self.select_preset()

    def show(self, viewer, image, slot=None):
        viewer.set_image(image)

    def open_image(self):
        if self.busy:
            return
        path = filedialog.askopenfilename(filetypes=[("图片", "*.png *.jpg *.jpeg *.bmp *.gif *.tif *.webp"), ("所有文件", "*.*")])
        if path:
            try:
                self.load_image(path)
            except Exception as exc:
                messagebox.showerror("无法加载图片", str(exc))

    def load_image(self, path):
        source = load_source_image(path)
        self.video_path = self.video_info = self.video_preview_source = None
        self.left_image.allow_upscale = self.right_image.allow_upscale = False
        self.video_bar.pack_forget()
        self.mode_combo.configure(values=tuple(MODE_LABELS))
        for value in self.metric_values.values():
            value.set('—')
        self.source = source
        self.path_text.set(Path(path).name)
        if self.auto_size.get():
            self.sync_native_dimensions()
        self._preview_key = None
        self.clear_result()
        self.progress["value"] = 0
        self.percent_text.set("就绪")
        self.update_source_preview()
        self.send_button.configure(state="disabled" if self.busy else "normal")
        self.send_button.configure(text='发送并处理')
        self.set_busy(False)

    def set_busy(self, busy):
        self.busy = busy
        for button in (self.open_button, self.open_video_button, self.refresh_button):
            button.configure(state="disabled" if busy else "normal")
        self.original_button.configure(state='disabled' if busy or self.video_path else 'normal')
        self.send_button.configure(state="disabled" if busy or self.source is None else "normal")
        self.size_preset.configure(state="disabled" if busy or self.video_path else "readonly")
        self.mode_combo.configure(state="disabled" if busy else "readonly")
        self.host_entry.configure(state="disabled" if busy else "normal")
        self.udp_port_entry.configure(state="disabled" if busy else "normal")
        self.bind_ip_combo.configure(state='disabled' if busy else 'readonly')
        self.hog_threshold_entry.configure(state="disabled" if busy else "normal")
        for widget in (self.video_size_combo,self.video_policy_combo):
            widget.configure(state='disabled' if busy else 'readonly')
        playing = self.video_session is not None
        self.video_pause_button.configure(state='normal' if playing else 'disabled')
        self.video_stop_button.configure(state='normal' if playing else 'disabled')
        self.update_size_controls()

    def send(self):
        if self.busy:
            return
        if self.video_path is not None:
            self.start_video()
            return
        if self.source is None:
            messagebox.showinfo("提示", "请先打开图片。")
            return
        try:
            width, height = self.dimensions()
            host, udp_port = network_endpoint(self.host.get(), self.udp_port.get())
            bind_ip = self.bind_ip_value()
            mode = MODE_LABELS[self.mode.get()]
            threshold = float(self.hog_threshold.get()) if mode == 8 else 0.0
            if not math.isfinite(threshold) or abs(threshold) > 100:
                raise ValueError("HOG 阈值请输入 -100 到 100 的有限数值；它是 SVM 得分，不是概率")
            source = prepare_image(self.source, width, height)
            if mode == 9:
                prepare_band(source)
            self.update_source_preview()
            mode_label = self.mode.get()
        except Exception as exc:
            messagebox.showerror("设置错误", str(exc))
            return
        self.set_busy(True)
        self.clear_result("正在等待 FPGA 回传…")
        self.progress["value"] = 0
        self.percent_text.set("0%")
        self.status.set("正在准备图片并连接 FPGA…")

        def worker():
            try:
                start = time.monotonic()
                if mode == 9:
                    gray = prepare_band(source)
                    with UdpImageClient(host, udp_port, bind_ip=bind_ip) as client:
                        decoded = BandClient(client).decode(gray, width, height,
                            progress=lambda done, total: self.events.put(("band_progress", done, total)),
                            stage=lambda message: self.events.put(("stage", message)))
                    self.events.put(("band_done", draw_band(source, decoded), decoded,
                                     time.monotonic()-start, client.retry_count))
                    return
                if mode == 8:
                    gray, geometry = prepare_hog(source)
                    with UdpImageClient(host, udp_port, bind_ip=bind_ip) as client:
                        scores = HOGClient(client).detect(gray,
                            progress=lambda done, total: self.events.put(("hog_progress", done, total)),
                            stage=lambda message: self.events.put(("stage", message)))
                    self.events.put(("stage", "正在逐项校验 495 个窗口得分…"))
                    if scores != detect_reference(gray):
                        raise ValueError("FPGA HOG 得分与整数参考不一致，请检查模型和 RTL")
                    image, boxes = draw_detections(source, scores, geometry, round(threshold * (1 << 22)))
                    label = f"单尺度行人检测 · {len(boxes)} 个候选框（得分非概率）"
                    self.events.put(("done", image, width, height, time.monotonic()-start, client.retry_count, label))
                    return
                encode_start = time.perf_counter()
                data = image_to_rgb565(source)
                encode_seconds = time.perf_counter()-encode_start
                with UdpImageClient(host, udp_port, bind_ip=bind_ip) as client:
                    network_start = time.perf_counter()
                    result = client.transfer(data, width, height, mode,
                                             progress=lambda done, total: self.events.put(("progress", done, total)))
                    network_seconds = time.perf_counter() - network_start
                    metrics = dict(network_seconds=network_seconds,
                                   image_Mbps=len(data)*8/network_seconds/1_000_000,
                                   window=client.active_window)
                self.events.put(("verify",))
                verify_start = time.perf_counter()
                if result != reference(data, mode, width, height):
                    raise ValueError("回传像素与整数参考模型不一致，请检查 RTL、模式及以太网链路")
                verify_seconds = time.perf_counter()-verify_start
                decode_start = time.perf_counter()
                image = rgb565_to_image(result, width, height)
                metrics.update(encode_seconds=encode_seconds,verify_seconds=verify_seconds,
                               decode_seconds=time.perf_counter()-decode_start,total_seconds=time.monotonic()-start)
                self.events.put(("done", image, width, height, time.monotonic() - start, client.retry_count, mode_label, metrics))
            except Exception as exc:
                self.events.put(("error", str(exc)))

        threading.Thread(target=worker, daemon=True).start()

    def poll(self):
        try:
            while True:
                event = self.events.get_nowait()
                if event[0] == "connection":
                    self.set_busy(False)
                    self.status.set(event[1])
                elif event[0] == "stage":
                    self.status.set(event[1])
                elif event[0] == "hog_progress":
                    percent = event[1] / event[2] * 85
                    self.progress["value"] = percent
                    self.percent_text.set(f"{percent:.0f}%")
                    self.status.set(f"正在上传 HOG 灰度帧 · {event[1]:,} / {event[2]:,} 字节")
                elif event[0] == "band_progress":
                    percent = event[1] / event[2] * 85
                    self.progress["value"] = percent
                    self.percent_text.set(f"{percent:.0f}%")
                    self.status.set(f"正在上传 Band 原始灰度图 · {event[1]:,} / {event[2]:,} 字节")
                elif event[0] == "band_done":
                    _, image, decoded, elapsed, retries = event
                    self.result = image
                    self.band_result = decoded
                    self.right_image.set_image(image)
                    self.save_button.configure(state="normal")
                    self.binary_button.configure(state="normal")
                    self.set_busy(False)
                    self.progress["value"] = 100
                    self.percent_text.set("已完成")
                    bits = sum(map(len, decoded.binary_rows()))
                    self.status.set(f"FPGA 解码完成 · {decoded.rows-2} 行 / {bits} 位 · 同步行已排除 · 绿圈1、红叉0、青圈同步 · {elapsed:.3f} 秒 · 重试 {retries} 次")
                elif event[0] == "progress":
                    percent = event[1] / event[2] * 100
                    self.progress["value"] = percent
                    self.percent_text.set(f"{percent:.0f}%")
                    self.status.set(f"正在接收 FPGA 结果 · {event[1]:,} / {event[2]:,} 字节")
                elif event[0] == "verify":
                    self.status.set("回传完成，正在逐像素校验结果…")
                elif event[0] == "done":
                    _, image, width, height, elapsed, retries, name, *extra = event
                    self.result = image
                    self.right_image.set_image(image)
                    self.save_button.configure(state="normal")
                    self.set_busy(False)
                    self.progress["value"] = 100
                    self.percent_text.set("已完成")
                    check_label = "计算校验通过" if name.startswith("单尺度行人检测") else "校验通过"
                    self.last_transfer_metrics = extra[0] if extra else None
                    if extra:
                        metric = extra[0]
                        self.metric_values['mbps'].set(f'{metric["image_Mbps"]:.2f}')
                        self.status.set(f"{check_label} · {name} · {width}×{height} · 传输 {metric['network_seconds']:.3f} 秒 / {metric['image_Mbps']:.1f} Mbps · 总计 {elapsed:.3f} 秒 · 重试 {retries} 次")
                    else:
                        self.status.set(f"{check_label} · {name} · {width}×{height} · {elapsed:.3f} 秒 · 重试 {retries} 次")
                    self.metric_values['latency'].set(f'{elapsed*1000:.1f}')
                    self.metric_values['retries'].set(str(retries))
                elif event[0] == "error":
                    self.set_busy(False)
                    self.percent_text.set("未完成")
                    self.status.set("传输失败：" + event[1])
                    messagebox.showerror("传输失败", event[1])
        except queue.Empty:
            pass
        if self._poll_video():
            return
        self._poll_job = self.root.after(15 if self.video_session is not None else 60, self.poll)

    def save(self):
        if self.result is not None:
            path = filedialog.asksaveasfilename(defaultextension=".png", filetypes=[("PNG 图片", "*.png"), ("BMP 图片", "*.bmp")])
            if path:
                try:
                    if self.band_result is not None:
                        bits_path = export_band(self.result, self.band_result, path)
                        self.status.set(f"已保存图像、0/1文本、采样CSV和报告：{bits_path}")
                    else:
                        self.result.save(path)
                        self.status.set(f"已保存：{path}")
                except Exception as exc:
                    messagebox.showerror("保存失败", str(exc))

    def show_binary(self):
        if self.band_result is None:
            return
        if self.binary_window is not None and self.binary_window.winfo_exists():
            self.binary_window.destroy()
        from tkinter.scrolledtext import ScrolledText
        window = tk.Toplevel(self.root)
        self.binary_window = window
        window.title("Band 二进制 · 同步行已排除")
        window.geometry("760x520")
        window.configure(background=COLORS['background'])
        frame = ttk.Frame(window, style="App.TFrame", padding=16)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="按行显示可见数据 · 边缘截断位置请结合黄色标记查看",
                  style="Subtitle.TLabel").pack(anchor="w", pady=(0, 10))
        text = ScrolledText(frame, font=("Consolas", 12), wrap="none", relief="flat", padx=12, pady=12)
        text.pack(fill="both", expand=True)
        text.insert("1.0", '\n'.join(f'{number+1:02d}  {bits}' for number, bits in enumerate(self.band_result.binary_rows())))
        text.configure(state="disabled")
        ttk.Button(frame, text="导出图像与二进制", command=self.save).pack(anchor="e", pady=(10, 0))

    def close(self):
        if self.video_session is not None:
            self._close_after_video = True
            self.stop_video()
            return
        if self.busy:
            messagebox.showinfo("传输进行中", "请等待当前传输完成或超时报错后关闭。")
        else:
            self.root.after_cancel(self._poll_job)
            self.root.destroy()


def main():
    parser = argparse.ArgumentParser(description="ZU4EV 千兆以太网图像工作台")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--self-test", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--report", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--input", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--test-mode", choices=("band", "hog", "gamma", "copy", "video_copy", "video_hog", "video_sobel25"), default="band", help=argparse.SUPPRESS)
    parser.add_argument('--snapshot',type=Path,help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.self_test:
        if args.report is None or args.input is None:
            parser.error("--self-test requires --report and --input")
        if args.test_mode.startswith('video_'):
            from video_gui_selftest import run
            return run(args.report,args.host,args.port,args.input,args.test_mode,snapshot=args.snapshot)
        from eth_gui_selftest import run
        return run(args.report, args.host, args.port, args.input, args.test_mode)
    app_root = tk.Tk()
    app = ImageApp(app_root)
    app.host.set(args.host)
    app.udp_port.set(str(args.port))
    app_root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
