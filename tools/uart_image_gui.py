"""FPGA image workbench with collapsible settings and interactive image views."""
from __future__ import annotations

from pathlib import Path
import argparse
import math
import queue
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from PIL import Image
from image_viewer import COLORS, ImageViewer
from uart_image import (ImageClient, MODE_LABELS, MAX_WIDTH, MAX_HEIGHT, image_to_rgb565,
                        open_serial, reference, rgb565_to_image, serial_ports,
                        load_source_image, prepare_image)
from hog_client import HOGClient, HOG_LABEL, prepare_hog, draw_detections
from hog_reference import detect_reference
from hog_model import THRESHOLD, SCORE_SHIFT, MODEL_ID
from band_client import BAND_LABEL, BandClient, prepare_band, draw_band, export_band

MODE_LABELS = {**MODE_LABELS, HOG_LABEL: 8, BAND_LABEL: 9}


class ImageApp:
    def __init__(self, root):
        self.root = root
        root.title("FPGA 图像工作台 · Band 解码")
        root.geometry("1180x780")
        root.minsize(960, 640)
        root.configure(background=COLORS["background"])
        self._configure_styles()
        self.events = queue.Queue()
        self.source = self.result = None
        self.band_result = None
        self.binary_window = None
        self.busy = False
        self._preview_key = None
        self._settings_visible = False
        self.port = tk.StringVar()
        self.baud = tk.StringVar(value="1500000")
        self.auto_size = tk.BooleanVar(value=True)
        self.width, self.height = tk.StringVar(), tk.StringVar()
        self.mode = tk.StringVar(value="Gamma 暗部提亮")
        self.hog_threshold = tk.StringVar(value=f"{THRESHOLD / (1 << SCORE_SHIFT):.4f}")
        self.status = tk.StringVar(value="打开一张图片，选择算法后发送到 FPGA。")
        self.path_text = tk.StringVar(value="尚未选择图片")
        self.connection_text = tk.StringVar()
        self.percent_text = tk.StringVar(value="就绪")

        outer = ttk.Frame(root, style="App.TFrame", padding=(24, 18, 24, 16))
        outer.pack(fill="both", expand=True)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(3, weight=1)
        header = ttk.Frame(outer, style="App.TFrame")
        header.grid(row=0, column=0, sticky="ew", pady=(0, 18))
        title = ttk.Frame(header, style="App.TFrame")
        title.pack(side="left")
        ttk.Label(title, text="图像工作台", style="Title.TLabel").pack(anchor="w")
        ttk.Label(title, text="FPGA 图像处理  /  增强 · 去噪 · 检测 · 点阵解码", style="Subtitle.TLabel").pack(anchor="w", pady=(4, 0))
        self.settings_button = ttk.Button(header, text="设置", command=self.toggle_settings)
        self.settings_button.pack(side="right")
        ttk.Label(header, textvariable=self.connection_text, style="Subtitle.TLabel").pack(side="right", padx=14)

        toolbar = ttk.Frame(outer, style="Card.TFrame", padding=(14, 12))
        toolbar.grid(row=1, column=0, sticky="ew", pady=(0, 12))
        toolbar.columnconfigure(1, weight=1)
        self.open_button = ttk.Button(toolbar, text="打开图片", command=self.open_image)
        self.open_button.grid(row=0, column=0, padx=(0, 14))
        ttk.Label(toolbar, textvariable=self.path_text, style="CardMuted.TLabel", width=1,
                  anchor="w").grid(row=0, column=1, sticky="ew", padx=(0, 16))
        self.mode_combo = ttk.Combobox(toolbar, textvariable=self.mode, values=tuple(MODE_LABELS),
                                      state="readonly", width=22)
        self.mode_combo.grid(row=0, column=2, padx=(0, 12))
        self.mode_combo.bind("<<ComboboxSelected>>", lambda event: self.update_source_preview())
        self.send_button = ttk.Button(toolbar, text="发送并处理", style="Primary.TButton",
                                      command=self.send, state="disabled")
        self.send_button.grid(row=0, column=3, padx=(0, 8))
        self.save_button = ttk.Button(toolbar, text="保存结果", command=self.save, state="disabled")
        self.save_button.grid(row=0, column=4)
        self.binary_button = ttk.Button(toolbar, text="查看0/1", command=self.show_binary, state="disabled")
        self.binary_button.grid(row=0, column=5, padx=(8, 0))
        self.binary_button.grid_remove()

        self.settings_panel = ttk.Frame(outer, style="Card.TFrame", padding=(16, 12))
        self.settings_panel.grid(row=2, column=0, sticky="ew", pady=(0, 12))
        self._build_settings()
        self.settings_panel.grid_remove()

        views = ttk.Frame(outer, style="App.TFrame")
        views.grid(row=3, column=0, sticky="nsew")
        views.columnconfigure((0, 1), weight=1, uniform="image")
        views.rowconfigure(1, weight=1)
        ttk.Label(views, text="滚轮缩放 · 拖拽移动 · 双击适应窗口",
                  style="Subtitle.TLabel").grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 10))
        self.left_image = ImageViewer(views, "发送图像", "打开图片后，在这里查看原图", self.open_image)
        self.right_image = ImageViewer(views, "FPGA 处理结果", "发送并处理后，在这里查看结果")
        self.left_image.grid(row=1, column=0, sticky="nsew", padx=(0, 7))
        self.right_image.grid(row=1, column=1, sticky="nsew", padx=(7, 0))
        progress_track = ttk.Frame(outer, style="App.TFrame", height=4)
        progress_track.grid(row=4, column=0, sticky="ew", pady=(16, 10))
        self.progress = ttk.Progressbar(progress_track, maximum=100, style="Accent.Horizontal.TProgressbar")
        self.progress.place(relwidth=1, relheight=1)
        status_bar = ttk.Frame(outer, style="App.TFrame")
        status_bar.grid(row=5, column=0, sticky="ew")
        status_bar.columnconfigure(0, weight=1)
        self.status_label = ttk.Label(status_bar, textvariable=self.status, style="Status.TLabel",
                                      wraplength=850)
        self.status_label.grid(row=0, column=0, sticky="w")
        ttk.Label(status_bar, textvariable=self.percent_text, style="Subtitle.TLabel").grid(row=0, column=1, padx=(12, 0))
        for variable in (self.port, self.baud, self.width, self.height):
            variable.trace_add("write", lambda *args: self.update_summary())
        root.bind("<Control-o>", lambda event: self.open_image())
        root.bind("<Control-s>", lambda event: self.save())
        root.bind("<Control-Return>", lambda event: self.send())
        root.protocol("WM_DELETE_WINDOW", self.close)
        self.refresh()
        self.update_summary()
        self._poll_job = root.after(60, self.poll)

    def _configure_styles(self):
        style = ttk.Style(self.root)
        style.theme_use("clam")
        style.configure(".", font=("Microsoft YaHei UI", 10), foreground=COLORS["text"])
        style.configure("App.TFrame", background=COLORS["background"])
        style.configure("Card.TFrame", background=COLORS["surface"])
        style.configure("Title.TLabel", background=COLORS["background"], foreground=COLORS["text"],
                        font=("Microsoft YaHei UI", 22, "bold"))
        style.configure("Subtitle.TLabel", background=COLORS["background"], foreground=COLORS["muted"],
                        font=("Microsoft YaHei UI", 9))
        style.configure("Card.TLabel", background=COLORS["surface"], foreground=COLORS["text"])
        style.configure("CardMuted.TLabel", background=COLORS["surface"], foreground=COLORS["muted"],
                        font=("Microsoft YaHei UI", 9))
        style.configure("Status.TLabel", background=COLORS["background"], foreground=COLORS["text"],
                        font=("Microsoft YaHei UI", 9))
        style.configure("TButton", padding=(12, 8), background=COLORS["surface"],
                        bordercolor=COLORS["border"], lightcolor=COLORS["surface"],
                        darkcolor=COLORS["surface"], relief="flat", focuscolor=COLORS["surface"])
        style.map("TButton", background=[("active", "#E8EFFB"), ("disabled", "#EEF1F5")],
                  foreground=[("disabled", "#9AA6B7")])
        style.configure("Primary.TButton", padding=(18, 8), background=COLORS["blue"],
                        foreground="white", bordercolor=COLORS["blue"], focuscolor=COLORS["blue"])
        style.map("Primary.TButton", background=[("disabled", "#A9C2F5"), ("active", "#1D4ED8")],
                  foreground=[("disabled", "#F4F7FF"), ("!disabled", "white")])
        style.configure("View.TButton", padding=(8, 4), font=("Microsoft YaHei UI", 9))
        style.configure("TCombobox", padding=6, fieldbackground="white", bordercolor=COLORS["border"],
                        arrowcolor=COLORS["muted"])
        style.map("TCombobox", fieldbackground=[("readonly", "white"), ("disabled", "#F1F4F8")])
        style.configure("TEntry", padding=6, bordercolor=COLORS["border"])
        style.configure("Accent.Horizontal.TProgressbar", thickness=5, background=COLORS["blue"],
                        troughcolor=COLORS["border"], borderwidth=0, lightcolor=COLORS["blue"],
                        darkcolor=COLORS["blue"])

    def _build_settings(self):
        panel = self.settings_panel
        ttk.Label(panel, text="串口", style="CardMuted.TLabel").grid(row=0, column=0, sticky="w")
        self.port_combo = ttk.Combobox(panel, textvariable=self.port, width=14)
        self.port_combo.grid(row=0, column=1, padx=(10, 8))
        self.refresh_button = ttk.Button(panel, text="刷新", command=self.refresh)
        self.refresh_button.grid(row=0, column=2)
        ttk.Label(panel, text="波特率", style="CardMuted.TLabel").grid(row=0, column=3, padx=(26, 10))
        self.baud_entry = ttk.Entry(panel, textvariable=self.baud, width=12)
        self.baud_entry.grid(row=0, column=4, sticky="w")
        ttk.Label(panel, text="8N1 · 无流控", style="CardMuted.TLabel").grid(row=0, column=5, padx=(16, 0), sticky="w")
        ttk.Label(panel, text="尺寸", style="CardMuted.TLabel").grid(row=1, column=0, sticky="w", pady=(12, 0))
        self.size_preset = ttk.Combobox(panel, state="readonly", width=14,
                                      values=("自动识别原图", "手动输入", "128×128", "320×240", "640×480", "1280×720", "1920×1080"))
        self.size_preset.set("自动识别原图")
        self.size_preset.grid(row=1, column=1, padx=(10, 8), pady=(12, 0))
        self.size_preset.bind("<<ComboboxSelected>>", self.select_preset)
        self.original_button = ttk.Button(panel, text="原图尺寸", command=self.use_original_size)
        self.original_button.grid(row=1, column=2, pady=(12, 0))
        size_fields = ttk.Frame(panel, style="Card.TFrame")
        size_fields.grid(row=1, column=3, columnspan=2, padx=(26, 0), pady=(12, 0), sticky="w")
        self.width_entry = ttk.Entry(size_fields, textvariable=self.width, width=6, state="readonly")
        self.width_entry.pack(side="left")
        ttk.Label(size_fields, text="×", style="CardMuted.TLabel").pack(side="left", padx=8)
        self.height_entry = ttk.Entry(size_fields, textvariable=self.height, width=6, state="readonly")
        self.height_entry.pack(side="left")
        for entry in (self.width_entry, self.height_entry):
            entry.bind("<Return>", lambda event: self.update_source_preview())
            entry.bind("<FocusOut>", lambda event: self.update_source_preview() if not self.busy else None)
        self.size_hint = ttk.Label(panel, text=f"最大 {MAX_WIDTH} × {MAX_HEIGHT} · RGB565", style="CardMuted.TLabel")
        self.size_hint.grid(row=1, column=5, padx=(16, 0), pady=(12, 0), sticky="w")
        self.hog_label = ttk.Label(panel, text="HOG 阈值", style="CardMuted.TLabel")
        self.hog_label.grid(row=2, column=0, sticky="w", pady=(12, 0))
        self.hog_threshold_entry = ttk.Entry(panel, textvariable=self.hog_threshold, width=14)
        self.hog_threshold_entry.grid(row=2, column=1, padx=(10, 8), pady=(12, 0))
        self.hog_note = ttk.Label(panel, text=f"提高可减少候选框 · 得分非概率 · 单尺度直立行人 · 模型 {MODEL_ID:08X}", style="CardMuted.TLabel")
        self.hog_note.grid(row=2, column=2, columnspan=4, sticky="w", pady=(12, 0))
        self.band_note = ttk.Label(panel, text="Band：近水平点阵 · 点距8～32像素 · 底部两行同步点 · FPGA 自动定位与判决", style="CardMuted.TLabel")
        self.band_note.grid(row=2, column=0, columnspan=6, sticky="w", pady=(12, 0))
        self.band_note.grid_remove()

    def toggle_settings(self):
        self._settings_visible = not self._settings_visible
        if self._settings_visible:
            self.settings_panel.grid()
        else:
            self.settings_panel.grid_remove()
        self.settings_button.configure(text="收起设置" if self._settings_visible else "设置")

    def update_summary(self):
        port = self.port.get().strip() or "未选择串口"
        baud = self.baud.get()
        speed = "1.5 Mbps" if baud == "1500000" else f"{baud} baud"
        sizing = "自动尺寸" if self.auto_size.get() else f"{self.width.get()} × {self.height.get()}"
        self.connection_text.set(f"{port}  ·  {speed}  ·  {sizing}")

    def refresh(self):
        try:
            ports = serial_ports()
            self.port_combo["values"] = [p[0] for p in ports]
            if ports and not self.port.get():
                self.port.set(next((device for device, name in ports if "USB" in name.upper()), ports[0][0]))
            if not ports:
                self.status.set("未检测到串口，请连接 USB 转 TTL 后，在设置中刷新。")
        except Exception as exc:
            self.status.set(str(exc))

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
        state = "disabled" if self.busy else ("readonly" if self.auto_size.get() else "normal")
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
        self.source = load_source_image(path)
        self.path_text.set(Path(path).name)
        if self.auto_size.get():
            self.sync_native_dimensions()
        self._preview_key = None
        self.clear_result()
        self.progress["value"] = 0
        self.percent_text.set("就绪")
        self.update_source_preview()
        self.send_button.configure(state="disabled" if self.busy else "normal")

    def set_busy(self, busy):
        self.busy = busy
        for button in (self.open_button, self.refresh_button, self.original_button):
            button.configure(state="disabled" if busy else "normal")
        self.send_button.configure(state="disabled" if busy or self.source is None else "normal")
        self.size_preset.configure(state="disabled" if busy else "readonly")
        self.mode_combo.configure(state="disabled" if busy else "readonly")
        self.port_combo.configure(state="disabled" if busy else "normal")
        self.baud_entry.configure(state="disabled" if busy else "normal")
        self.hog_threshold_entry.configure(state="disabled" if busy else "normal")
        self.update_size_controls()

    def send(self):
        if self.busy:
            return
        if self.source is None:
            messagebox.showinfo("提示", "请先打开图片。")
            return
        try:
            width, height = self.dimensions()
            baud = int(self.baud.get())
            if baud <= 0 or not self.port.get().strip():
                raise ValueError("请在设置中选择串口并输入有效波特率")
            mode = MODE_LABELS[self.mode.get()]
            threshold = float(self.hog_threshold.get()) if mode == 8 else 0.0
            if not math.isfinite(threshold) or abs(threshold) > 100:
                raise ValueError("HOG 阈值请输入 -100 到 100 的有限数值；它是 SVM 得分，不是概率")
            source = prepare_image(self.source, width, height)
            if mode == 9:
                prepare_band(source)
            self.update_source_preview()
            port = self.port.get().strip()
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
                    with open_serial(port, baud) as stream:
                        stream.reset_input_buffer()
                        client = ImageClient(stream, baud)
                        decoded = BandClient(client).decode(gray, width, height,
                            progress=lambda done, total: self.events.put(("band_progress", done, total)),
                            stage=lambda message: self.events.put(("stage", message)))
                    self.events.put(("band_done", draw_band(source, decoded), decoded,
                                     time.monotonic()-start, client.retry_count))
                    return
                if mode == 8:
                    gray, geometry = prepare_hog(source)
                    with open_serial(port, baud) as stream:
                        stream.reset_input_buffer()
                        client = ImageClient(stream, baud)
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
                data = image_to_rgb565(source)
                with open_serial(port, baud) as stream:
                    stream.reset_input_buffer()
                    client = ImageClient(stream, baud)
                    result = client.transfer(data, width, height, mode,
                                             progress=lambda done, total: self.events.put(("progress", done, total)))
                self.events.put(("verify",))
                if result != reference(data, mode, width, height):
                    raise ValueError("回传像素与整数参考模型不一致，请检查 RTL、模式及串口链路")
                image = rgb565_to_image(result, width, height)
                self.events.put(("done", image, width, height, time.monotonic() - start, client.retry_count, mode_label))
            except Exception as exc:
                self.events.put(("error", str(exc)))

        threading.Thread(target=worker, daemon=True).start()

    def poll(self):
        try:
            while True:
                event = self.events.get_nowait()
                if event[0] == "stage":
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
                    _, image, width, height, elapsed, retries, name = event
                    self.result = image
                    self.right_image.set_image(image)
                    self.save_button.configure(state="normal")
                    self.set_busy(False)
                    self.progress["value"] = 100
                    self.percent_text.set("已完成")
                    check_label = "计算校验通过" if name.startswith("单尺度行人检测") else "校验通过"
                    self.status.set(f"{check_label} · {name} · {width}×{height} · {elapsed:.3f} 秒 · 重试 {retries} 次")
                elif event[0] == "error":
                    self.set_busy(False)
                    self.percent_text.set("未完成")
                    self.status.set("传输失败：" + event[1])
                    messagebox.showerror("传输失败", event[1])
        except queue.Empty:
            pass
        self._poll_job = self.root.after(60, self.poll)

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
        if self.busy:
            messagebox.showinfo("传输进行中", "请等待当前传输完成或超时报错后关闭。")
        else:
            self.root.after_cancel(self._poll_job)
            self.root.destroy()


def main():
    parser = argparse.ArgumentParser(description="FPGA UART image GUI")
    parser.add_argument("--self-test", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--hog-self-test", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--band-self-test", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--input", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--report", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--port", help=argparse.SUPPRESS)
    parser.add_argument("--test-width", type=int, default=128, help=argparse.SUPPRESS)
    parser.add_argument("--test-height", type=int, default=128, help=argparse.SUPPRESS)
    parser.add_argument("--test-auto-suite", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--test-filter-suite", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--test-enhance-suite", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.band_self_test:
        if args.report is None or not args.port or args.input is None:
            parser.error("--band-self-test requires --report, --port and --input")
        from band_client import gui_selftest
        return gui_selftest(args.report, args.port, args.input)
    if args.hog_self_test:
        if args.report is None or not args.port or args.input is None:
            parser.error("--hog-self-test requires --report, --port and --input")
        from hog_client import gui_selftest
        return gui_selftest(args.report,args.port,args.input)
    if args.self_test:
        if args.report is None:
            parser.error("--self-test requires --report")
        from frozen_selftest import run
        return run(args.report, args.port, args.test_width, args.test_height,
                   args.test_auto_suite, args.test_filter_suite, args.test_enhance_suite)
    app_root = tk.Tk()
    ImageApp(app_root)
    app_root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
