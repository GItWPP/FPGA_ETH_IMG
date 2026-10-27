"""Band UART client, FPGA-result rendering and binary export; no PC detection."""
from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
import csv
import json
import secrets
import struct
import time
from PIL import ImageDraw
from uart_image import Packet, ProtocolError

BAND_LABEL = 'Band 点阵二进制解码'
ERRORS = {1: '未找到有效数据带（至少4行、每行至少5点）', 2: '底部两行同步点校验失败',
          3: '点、行或结果缓存溢出', 4: '点间距超出8～32像素范围', 5: '数据行网格定位失败'}


def prepare_band(image):
    width, height = image.size
    if not (16 <= width <= 512 and 16 <= height <= 512):
        raise ValueError('Band 首版支持原生16～512 × 16～512像素，请选择合适尺寸；小圆点应保留细节')
    return image.convert('L').tobytes()


@dataclass
class BandResult:
    width: int
    height: int
    rows: int
    pitch_q8: int
    detected_dots: int
    words: list[int]
    calculation_seconds: float = 0.0

    @property
    def cells(self):
        return [dict(x=w&511, y=(w>>9)&511, bit=(w>>18)&1, sync=bool((w>>19)&1),
                     partial=bool((w>>20)&1), low_confidence=bool((w>>21)&1), row=(w>>22)&63) for w in self.words]

    def binary_rows(self, sync=False):
        first, last = (self.rows-2, self.rows) if sync else (0, self.rows-2)
        cells = self.cells
        return [''.join(str(c['bit']) for c in cells if c['row'] == row) for row in range(first, last)]


class BandClient:
    def __init__(self, client):
        self.client = client

    def info(self):
        data = self.client.transact(Packet(0x2f), 16).payload
        if struct.unpack('<4sHHBBHI', data) != (b'BND1', 512, 512, 1, 2, 4096, 0):
            raise ProtocolError('FPGA Band接口不兼容，请下载对应bitstream')
        return data

    def decode(self, gray, width, height, progress=None, stage=None, transfer_id=None):
        if not (16 <= width <= 512 and 16 <= height <= 512) or len(gray) != width*height:
            raise ValueError('Band requires 16..512 by 16..512 gray8 pixels')
        self.info()
        tid = secrets.randbelow(65535)+1 if transfer_id is None else transfer_id
        self.client.transact(Packet(0x20, tid, 0, struct.pack('<HH', width, height)), 0)
        seq = 1
        for offset in range(0, len(gray), 1024):
            self.client.transact(Packet(0x21, tid, seq, gray[offset:offset+1024]), 0)
            seq += 1
            if progress:
                progress(min(offset+1024, len(gray)), len(gray))
        if stage:
            stage('FPGA 正在定位同步行、拟合网格并解码…')
        start = time.monotonic()
        data = self.client.transact(Packet(0x22, tid, seq), 16, timeout=5).payload
        elapsed = time.monotonic()-start
        magic, count, rows, status, pitch, rw, rh, dots = struct.unpack('<4sHBBHHHH', data)
        if magic != b'BND1' or (rw, rh) != (width, height):
            raise ProtocolError('Band返回的接口或尺寸错误')
        if status:
            raise ProtocolError('FPGA Band：'+ERRORS.get(status, f'未知状态{status}'))
        if not (4 <= rows <= 64 and 1 <= count <= 4096 and 2048 <= pitch <= 8192 and dots <= 2048):
            raise ProtocolError('Band返回的结果范围错误')
        words = []
        seq += 1
        if stage:
            stage('正在读取 FPGA 的采样坐标与二进制结果…')
        for offset in range(0, count, 256):
            size = min(256, count-offset)
            packet = self.client.transact(Packet(0x23, tid, seq, struct.pack('<HH', offset, size)), size*4)
            words.extend(struct.unpack(f'<{size}I', packet.payload))
            seq += 1
        result = BandResult(width, height, rows, pitch, dots, words, elapsed)
        previous = (-1, -1)
        for cell, word in zip(result.cells, words):
            key = (cell['row'], cell['x'])
            if (word >> 28 or cell['x'] >= width or cell['y'] >= height or cell['row'] >= rows
                or cell['sync'] != (cell['row'] >= rows-2) or key <= previous):
                raise ProtocolError('Band采样坐标、顺序或标志错误')
            previous = key
        if any(not row for row in result.binary_rows()+result.binary_rows(True)):
            raise ProtocolError('Band返回了空数据行')
        return result


def draw_band(image, result):
    annotated = image.convert('RGB').copy()
    draw = ImageDraw.Draw(annotated)
    for cell in result.cells:
        x, y = cell['x'], cell['y']
        color = '#00BDDC' if cell['sync'] else ('#16DB71' if cell['bit'] else '#FF663D')
        if cell['bit']:
            draw.ellipse((x-4, y-4, x+4, y+4), outline=color, width=1)
        else:
            draw.line((x-2, y, x+2, y), fill=color)
            draw.line((x, y-2, x, y+2), fill=color)
        if cell['partial']:
            draw.line((max(0, x-2), y+5, min(result.width-1, x+2), y+5), fill='#FFD166')
    return annotated


def export_band(image, result, image_path):
    """Export row-preserving bits; sync rows have a separate file."""
    image_path = Path(image_path)
    image_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(image_path)
    stem = image_path.with_suffix('')
    bits_path = stem.with_name(stem.name+'_bits.txt')
    bits_path.write_text('\n'.join(result.binary_rows())+'\n', encoding='ascii')
    stem.with_name(stem.name+'_sync.txt').write_text('\n'.join(result.binary_rows(True))+'\n', encoding='ascii')
    cells = result.cells
    with stem.with_name(stem.name+'_cells.csv').open('w', encoding='utf-8-sig', newline='') as file:
        writer = csv.DictWriter(file, fieldnames=list(cells[0]))
        writer.writeheader()
        writer.writerows(cells)
    report = dict(width=result.width, height=result.height, total_rows=result.rows, data_rows=result.rows-2,
                  pitch_pixels=result.pitch_q8/256, detected_dots=result.detected_dots,
                  calculation_seconds=result.calculation_seconds, cells=len(cells),
                  data_bits=sum(map(len, result.binary_rows())),
                  boundary_policy='Visible rows only; partial border sites are flagged; no unseen bits are recovered.',
                  words=result.words)
    stem.with_name(stem.name+'_report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    return bits_path


def gui_selftest(report_path, port, input_path):
    import sys
    import tkinter as tk
    from uart_image_gui import ImageApp
    import uart_image_gui
    report_path = Path(report_path)
    report = dict(status='running', frozen=bool(getattr(sys, 'frozen', False)))
    root = tk.Tk()
    root.attributes('-alpha', 0)
    app = ImageApp(root)
    errors = []
    uart_image_gui.messagebox.showerror = lambda title, message: errors.append(str(message))
    try:
        app.load_image(input_path)
        app.port.set(port)
        app.mode.set(BAND_LABEL)
        app.send()
        deadline = time.monotonic()+45
        while app.busy and time.monotonic() < deadline:
            root.update()
            time.sleep(0.01)
        assert not app.busy and not errors and app.band_result is not None, errors
        result_path = report_path.with_suffix('.png')
        bits = export_band(app.result, app.band_result, result_path)
        app.show_binary()
        root.update()
        assert app.binary_window.winfo_exists()
        report.update(status='passed', gui_status=app.status.get(), result=str(result_path), bits=str(bits), words=app.band_result.words)
    except Exception as exc:
        report.update(status='failed', error=repr(exc), gui_errors=errors)
    finally:
        root.destroy()
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    return 0 if report['status'] == 'passed' else 1
