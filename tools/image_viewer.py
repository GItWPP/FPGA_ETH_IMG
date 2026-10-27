"""Viewport-only image rendering with cursor-centered zoom and drag panning."""
from __future__ import annotations

import math
import tkinter as tk
from tkinter import ttk

from PIL import Image, ImageTk

COLORS = {"background": "#F0F0F0", "surface": "#FFFFFF", "text": "#202020",
          "muted": "#6A6A6A", "border": "#CFCFCF", "blue": "#1769AA",
          "viewport": "#F7F7F7"}


class ImageViewer(tk.Frame):
    MIN_SCALE, MAX_SCALE = 0.01, 32.0

    def __init__(self, parent, title, empty_text, open_command=None):
        super().__init__(parent, background=COLORS["surface"], highlightthickness=1,
                         highlightbackground=COLORS["border"], borderwidth=0)
        self.image = None
        self.scale = 1.0
        self.offset_x = self.offset_y = 0.0
        self.fit_mode = True
        self.allow_upscale = False
        self._photo = None
        self._scheduler = self.winfo_toplevel()
        self._render_job = None
        self._drag = None
        self._viewport = (1, 1)
        self._open_command = open_command
        self.empty_text = empty_text
        self.rendered_size = (0, 0)
        header = tk.Frame(self, background=COLORS["surface"])
        header.pack(fill="x", padx=16, pady=(14, 12))
        tk.Label(header, text=title, font=("Microsoft YaHei UI", 11, "bold"),
                 foreground=COLORS["text"], background=COLORS["surface"]).pack(side="left")
        self.info = tk.StringVar(value="未加载")
        tk.Label(header, textvariable=self.info, foreground=COLORS["muted"],
                 background=COLORS["surface"], font=("Segoe UI", 9)).pack(side="right")
        self.canvas = tk.Canvas(self, background=COLORS["viewport"], highlightthickness=0,
                                borderwidth=0, width=300, height=240)
        self.canvas.pack(fill="both", expand=True, padx=1)
        footer = tk.Frame(self, background=COLORS["surface"])
        footer.pack(fill="x", padx=12, pady=10)
        self.zoom_out_button = ttk.Button(footer, text="−", width=3, style="View.TButton",
                                          command=lambda: self.zoom(1 / 1.25))
        self.zoom_out_button.pack(side="left")
        self.zoom_text = tk.StringVar(value="—")
        tk.Label(footer, textvariable=self.zoom_text, width=8, background=COLORS["surface"],
                 foreground=COLORS["text"], font=("Segoe UI", 9)).pack(side="left", padx=2)
        self.zoom_in_button = ttk.Button(footer, text="+", width=3, style="View.TButton",
                                         command=lambda: self.zoom(1.25))
        self.zoom_in_button.pack(side="left")
        self.fit_button = ttk.Button(footer, text="适应", style="View.TButton", command=self.fit_image)
        self.fit_button.pack(side="right")
        self.actual_button = ttk.Button(footer, text="1:1", style="View.TButton", command=self.actual_size)
        self.actual_button.pack(side="right", padx=(0, 6))
        self.canvas.bind("<Configure>", self._on_resize)
        self.canvas.bind("<MouseWheel>", self._on_wheel)
        self.canvas.bind("<Button-4>", lambda event: self._on_wheel(event, 1))
        self.canvas.bind("<Button-5>", lambda event: self._on_wheel(event, -1))
        self.canvas.bind("<ButtonPress-1>", self._on_press)
        self.canvas.bind("<B1-Motion>", self._on_drag)
        self.canvas.bind("<ButtonRelease-1>", self._on_release)
        self.canvas.bind("<Double-Button-1>", self._on_double_click)
        self.bind("<Destroy>", self._on_destroy)
        self.clear()

    def viewport_size(self):
        return max(1, self.canvas.winfo_width()), max(1, self.canvas.winfo_height())

    def set_image(self, image):
        self.image = image.convert("RGB").copy()
        self.info.set(f"{image.width} × {image.height} px")
        self.canvas.configure(cursor="hand2")
        self._set_controls(True)
        self.fit_image()

    def update_image(self, image):
        """Replace a video frame while retaining the user's current viewport."""
        if self.image is None or self.image.size != image.size:
            self.set_image(image)
            return
        self.image = image.convert('RGB').copy()
        self.info.set(f'{image.width} × {image.height} px')
        self._schedule_draw()

    def clear(self, text=None):
        self.image = None
        self._photo = None
        self._drag = None
        self.rendered_size = (0, 0)
        self.info.set("未加载")
        self.zoom_text.set("—")
        self.canvas.configure(cursor="arrow")
        self._empty_message = text or self.empty_text
        self._set_controls(False)
        self._schedule_draw()

    def _set_controls(self, enabled):
        for button in (self.zoom_out_button, self.zoom_in_button, self.fit_button, self.actual_button):
            button.configure(state="normal" if enabled else "disabled")

    def image_point(self, x, y):
        return (x - self.offset_x) / self.scale, (y - self.offset_y) / self.scale

    def fit_image(self):
        self.fit_mode = True
        if self.image is None:
            return
        width, height = self.viewport_size()
        if width > 1 and height > 1:
            self.scale = min((width - 32) / self.image.width, (height - 32) / self.image.height,
                             self.MAX_SCALE if self.allow_upscale else 1.0)
            self.scale = max(self.MIN_SCALE, self.scale)
            self.offset_x = (width - self.image.width * self.scale) / 2
            self.offset_y = (height - self.image.height * self.scale) / 2
        self._schedule_draw()

    def actual_size(self):
        if self.image is not None:
            self.zoom(1 / self.scale)

    def zoom(self, factor, anchor=None):
        if self.image is None:
            return
        width, height = self.viewport_size()
        anchor = anchor or (width / 2, height / 2)
        ix, iy = self.image_point(*anchor)
        self.scale = min(self.MAX_SCALE, max(self.MIN_SCALE, self.scale * factor))
        self.offset_x, self.offset_y = anchor[0] - ix * self.scale, anchor[1] - iy * self.scale
        self.fit_mode = False
        self._constrain_offset()
        self._schedule_draw()

    def pan(self, dx, dy):
        if self.image is None:
            return
        self.offset_x += dx
        self.offset_y += dy
        self.fit_mode = False
        self._constrain_offset()
        self._schedule_draw()

    def _constrain_offset(self):
        if self.image is None:
            return
        width, height = self.viewport_size()
        scaled_width, scaled_height = self.image.width * self.scale, self.image.height * self.scale
        self.offset_x = (min(width - scaled_width, max(0, self.offset_x)) if scaled_width <= width else
                         min(24, max(width - scaled_width - 24, self.offset_x)))
        self.offset_y = (min(height - scaled_height, max(0, self.offset_y)) if scaled_height <= height else
                         min(24, max(height - scaled_height - 24, self.offset_y)))

    def _on_wheel(self, event, direction=None):
        if direction is None:
            direction = event.delta / 120
        self.zoom(1.2 ** max(-8, min(8, direction)), (event.x, event.y))
        return "break"

    def _on_press(self, event):
        if self.image is not None:
            self._drag = (event.x, event.y, self.offset_x, self.offset_y)
            self.canvas.configure(cursor="fleur")

    def _on_drag(self, event):
        if self._drag is not None:
            x, y, ox, oy = self._drag
            self.offset_x, self.offset_y = ox + event.x - x, oy + event.y - y
            self.fit_mode = False
            self._constrain_offset()
            self._schedule_draw()

    def _on_release(self, event):
        self._drag = None
        self.canvas.configure(cursor="hand2" if self.image is not None else "arrow")

    def _on_double_click(self, event):
        if self.image is not None:
            self.fit_image()
        elif self._open_command is not None:
            self._open_command()
        return "break"

    def _on_resize(self, event):
        if self.image is not None:
            if self.fit_mode:
                self.fit_image()
            else:
                self.offset_x += (event.width - self._viewport[0]) / 2
                self.offset_y += (event.height - self._viewport[1]) / 2
                self._constrain_offset()
        self._viewport = (event.width, event.height)
        self._schedule_draw()

    def _schedule_draw(self):
        if self._render_job is None:
            self._render_job = self._scheduler.after_idle(self._draw)

    def _draw(self):
        self._render_job = None
        self.canvas.delete("all")
        width, height = self.viewport_size()
        if self.image is None:
            cx, cy = width / 2, height / 2 - 18
            self.canvas.create_rectangle(cx - 24, cy - 22, cx + 24, cy + 14,
                                         outline="#ABB8CB", width=2)
            self.canvas.create_oval(cx + 7, cy - 14, cx + 14, cy - 7, fill="#ABB8CB", outline="")
            self.canvas.create_line(cx - 19, cy + 8, cx - 6, cy - 5, cx + 4, cy + 5,
                                    cx + 11, cy - 1, cx + 20, cy + 8, fill="#ABB8CB", width=2)
            self.canvas.create_text(cx, cy + 45, text=self._empty_message, fill=COLORS["muted"],
                                    font=("Microsoft YaHei UI", 10), width=max(100, width - 32))
            return
        # Crop before scaling: even at 3200%, memory is bounded by the viewport.
        left = max(0, math.floor(-self.offset_x / self.scale))
        top = max(0, math.floor(-self.offset_y / self.scale))
        right = min(self.image.width, math.ceil((width - self.offset_x) / self.scale))
        bottom = min(self.image.height, math.ceil((height - self.offset_y) / self.scale))
        if right <= left or bottom <= top:
            self.rendered_size = (0, 0)
            return
        tile = self.image.crop((left, top, right, bottom))
        size = max(1, round((right - left) * self.scale)), max(1, round((bottom - top) * self.scale))
        resample = Image.Resampling.NEAREST if self.scale >= 1 else Image.Resampling.LANCZOS
        if self.allow_upscale and 1 < self.scale < 2:
            resample = Image.Resampling.BILINEAR
        tile = tile.resize(size,resample)
        self._photo = ImageTk.PhotoImage(tile)
        self.rendered_size = size
        self.canvas.create_image(self.offset_x + left * self.scale, self.offset_y + top * self.scale,
                                 image=self._photo, anchor="nw")
        self.zoom_text.set(f"{self.scale * 100:.0f}%")

    def _on_destroy(self, event):
        if event.widget is self and self._render_job is not None:
            self._scheduler.after_cancel(self._render_job)
            self._render_job = None
