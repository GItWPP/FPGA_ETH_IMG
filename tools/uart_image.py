"""UART image protocol, RGB565 reference model, and command line client.

Run protocol, image and GUI tests with: python uart_image.py selftest
Image tests and serial commands use: pip install -r requirements.txt
"""
from __future__ import annotations

import argparse
from array import array
import binascii
import math
from dataclasses import dataclass
from pathlib import Path
import secrets
import struct
import sys
import time

MAGIC = bytes.fromhex("55 AA 5A A5")
VERSION = 1
MAX_PAYLOAD = 1024
MAX_WIDTH, MAX_HEIGHT = 1920, 1080
PING, START, DATA, END, ERROR = 1, 2, 3, 4, 0xFF
MODES = {"copy": 0, "gray": 1, "invert": 2, "mean": 3, "median": 4, "sobel": 5,
         "gamma": 6, "sharpen": 7}
MODE_LABELS = {"原图回传": 0, "灰度化": 1, "反色": 2,
               "均值去噪（3×3）": 3, "中值去噪（3×3）": 4, "Sobel 边缘检测": 5,
               "Gamma 暗部提亮": 6, "彩色锐化（3×3）": 7}
FILTER_MODES = frozenset((3, 4, 5, 7))
MAX_FILTER_PIXELS = 168
ERRORS = {1: "unknown command", 2: "invalid arguments", 3: "no matching session",
          4: "unexpected sequence", 5: "invalid image length", 6: "conflicting retry"}
HEADER = struct.Struct("<BBHHH")


def crc16(data: bytes) -> int:
    return binascii.crc_hqx(data, 0xFFFF)


@dataclass(frozen=True)
class Packet:
    cmd: int
    transfer_id: int = 0
    seq: int = 0
    payload: bytes = b""

    def encode(self) -> bytes:
        if len(self.payload) > MAX_PAYLOAD:
            raise ValueError("payload exceeds 1024 bytes")
        body = HEADER.pack(VERSION, self.cmd, self.transfer_id, self.seq, len(self.payload)) + self.payload
        return MAGIC + body + struct.pack("<H", crc16(body))


class Decoder:
    """Incremental parser; scan again after malformed headers or CRC errors."""
    def __init__(self):
        self.buffer = bytearray()
        self.bad_crc = 0

    def reset(self):
        self.buffer.clear()

    def feed(self, data: bytes) -> list[Packet]:
        self.buffer.extend(data)
        result = []
        while True:
            start = self.buffer.find(MAGIC)
            if start < 0:
                self.buffer[:] = self.buffer[-3:]
                break
            del self.buffer[:start]
            if len(self.buffer) < 12:
                break
            version, cmd, transfer_id, seq, length = HEADER.unpack_from(self.buffer, 4)
            if version != VERSION or length > MAX_PAYLOAD:
                del self.buffer[0]
                continue
            size = 14 + length
            if len(self.buffer) < size:
                break
            body = self.buffer[4:12 + length]
            if crc16(body) != struct.unpack_from("<H", self.buffer, 12 + length)[0]:
                self.bad_crc += 1
                del self.buffer[0]
                continue
            result.append(Packet(cmd, transfer_id, seq, bytes(self.buffer[12:12 + length])))
            del self.buffer[:size]
        return result


def luminance(pixel: int) -> int:
    r5, g6, b5 = pixel >> 11, (pixel >> 5) & 63, pixel & 31
    r, g, b = (r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2)
    return (77 * r + 150 * g + 29 * b) >> 8


def gray565(value: int) -> int:
    return ((value >> 3) << 11) | ((value >> 2) << 5) | (value >> 3)


def process_pixel(pixel: int, mode: int) -> int:
    if mode == 0:
        return pixel
    if mode == 2:
        return pixel ^ 0xFFFF
    if mode == 6:
        red = math.isqrt((pixel >> 11) * 31)
        green = math.isqrt(((pixel >> 5) & 63) * 63)
        blue = math.isqrt((pixel & 31) * 31)
        return (red << 11) | (green << 5) | blue
    if mode != 1:
        raise ValueError("invalid mode")
    return gray565(luminance(pixel))


def filter_kernel(pixels, mode: int) -> int:
    """Independent scalar definition; input is nine RGB565 pixels in row order."""
    if len(pixels) != 9:
        raise ValueError("a 3x3 kernel requires nine pixels")
    if mode in (3, 4):
        channels = [[(p >> shift) & mask for p in pixels] for shift, mask in ((11, 31), (5, 63), (0, 31))]
        values = [sum(c) // 9 if mode == 3 else sorted(c)[4] for c in channels]
        return (values[0] << 11) | (values[1] << 5) | values[2]
    if mode == 5:
        a, b, c, d, _, f, g, h, i = [luminance(p) for p in pixels]
        gx, gy = -a + c - 2 * d + 2 * f - g + i, -a - 2 * b - c + g + 2 * h + i
        return gray565(min(255, abs(gx) + abs(gy)))
    if mode == 7:
        values = []
        for shift, maximum in ((11, 31), (5, 63), (0, 31)):
            center = (pixels[4] >> shift) & maximum
            surround = sum((pixels[index] >> shift) & maximum for index in (1, 3, 5, 7))
            values.append(min(maximum, max(0, 5 * center - surround)))
        return (values[0] << 11) | (values[1] << 5) | values[2]
    raise ValueError("invalid neighborhood mode")


def filter_reference(data: bytes, width: int, height: int, mode: int) -> bytes:
    """Full-image model with replicated borders; independent of packet tiling."""
    if not (1 <= width <= MAX_WIDTH and 1 <= height <= MAX_HEIGHT) or len(data) != width * height * 2:
        raise ValueError("filter dimensions do not match RGB565 image")
    pixels = array("H")
    pixels.frombytes(data)
    if sys.byteorder != "little":
        pixels.byteswap()
    # Convert once for Sobel, avoiding nine redundant RGB conversions per pixel.
    source = bytearray(map(luminance, pixels)) if mode == 5 else pixels
    result = bytearray(len(data))
    for y in range(height):
        top, middle, bottom = max(0, y - 1) * width, y * width, min(height - 1, y + 1) * width
        for x in range(width):
            left, right = max(0, x - 1), min(width - 1, x + 1)
            window = [source[row + col] for row in (top, middle, bottom) for col in (left, x, right)]
            if mode == 5:
                a, b, c, d, _, f, g, h, i = window
                gx, gy = -a + c - 2 * d + 2 * f - g + i, -a - 2 * b - c + g + 2 * h + i
                value = gray565(min(255, abs(gx) + abs(gy)))
            else:
                value = filter_kernel(window, mode)
            struct.pack_into("<H", result, (middle + x) * 2, value)
    return bytes(result)


def reference(data: bytes, mode: int, width: int | None = None, height: int | None = None) -> bytes:
    if mode not in MODES.values():
        raise ValueError("invalid mode")
    if len(data) % 2:
        raise ValueError("RGB565 requires an even byte count")
    if mode == 0:
        return bytes(data)
    if mode == 2:
        return bytes(value ^ 0xFF for value in data)
    if mode in FILTER_MODES:
        if width is None or height is None:
            raise ValueError("neighborhood reference requires image dimensions")
        return filter_reference(data, width, height, mode)
    # A fixed output buffer avoids millions of short byte objects for 1080p.
    result = bytearray(len(data))
    for index, (pixel,) in enumerate(struct.iter_unpack("<H", data)):
        struct.pack_into("<H", result, index * 2, process_pixel(pixel, mode))
    return bytes(result)


def iter_filter_tiles(data: bytes, width: int, height: int, max_payload: int = MAX_PAYLOAD):
    """Gather raw neighboring rows/columns only; all filtering runs in the FPGA."""
    if len(data) != width * height * 2 or width < 1 or height < 1:
        raise ValueError("filter dimensions do not match RGB565 image")
    count_limit = min(MAX_FILTER_PIXELS, (max_payload - 14) // 6)
    if not 20 <= max_payload <= MAX_PAYLOAD or count_limit < 1:
        raise ValueError("filter payload capacity must be within 20..1024")
    for y in range(height):
        for x in range(0, width, count_limit):
            count = min(count_limit, width - x)
            pieces = [struct.pack("<H", count)]
            for row in (max(0, y - 1), y, min(height - 1, y + 1)):
                base = row * width * 2
                if x == 0:
                    pieces.append(data[base:base + 2])
                pieces.append(data[base + max(0, x - 1) * 2:base + min(width, x + count + 1) * 2])
                if x + count == width:
                    pieces.append(data[base + (width - 1) * 2:base + width * 2])
            yield b"".join(pieces), count * 2


def image_to_rgb565(image) -> bytes:
    rgb = image.convert("RGB").tobytes()
    result = bytearray(len(rgb) // 3 * 2)
    for i in range(0, len(rgb), 3):
        r, g, b = rgb[i:i + 3]
        pixel = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        struct.pack_into("<H", result, i // 3 * 2, pixel)
    return bytes(result)


def rgb565_to_image(data: bytes, width: int, height: int):
    from PIL import Image
    if len(data) != width * height * 2:
        raise ValueError("image byte count does not match dimensions")
    rgb = bytearray(width * height * 3)
    for i, (pixel,) in enumerate(struct.iter_unpack("<H", data)):
        r, g, b = pixel >> 11, (pixel >> 5) & 63, pixel & 31
        rgb[i * 3:i * 3 + 3] = bytes(((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)))
    return Image.frombytes("RGB", (width, height), bytes(rgb))


def load_source_image(path):
    """Decode the file and honor its display orientation before reading dimensions."""
    from PIL import Image, ImageOps
    with Image.open(path) as image:
        return ImageOps.exif_transpose(image).convert("RGB")


def prepare_image(image, width: int | None = None, height: int | None = None):
    """Keep native dimensions by default; resize only for an explicit size pair."""
    from PIL import Image
    if width is None and height is None:
        width, height = image.size
    elif width is None or height is None:
        raise ValueError("provide both --width and --height for manual resize")
    if not (1 <= width <= MAX_WIDTH and 1 <= height <= MAX_HEIGHT):
        raise ValueError(f"image is {width}x{height}; supported range is 1..{MAX_WIDTH} by 1..{MAX_HEIGHT}; choose a manual size to resize")
    if image.size == (width, height):
        return image.copy()
    return image.resize((width, height), Image.Resampling.LANCZOS)


class ProtocolError(RuntimeError):
    pass


class ImageClient:
    def __init__(self, stream, baud: int = 1_500_000, attempts: int = 3):
        self.stream = stream
        self.baud = baud
        self.attempts = attempts
        self.decoder = Decoder()
        self.retry_count = 0

    def transact(self, packet: Packet, expected_length: int, *, timeout: float | None = None) -> Packet:
        encoded = packet.encode()
        if timeout is None:
            timeout = max(0.5, (len(encoded) + expected_length + 14) * 20 / self.baud + 0.2)
        for attempt in range(self.attempts):
            if attempt:
                self.retry_count += 1
                self.decoder.reset()
                self.stream.reset_input_buffer()
            remaining = memoryview(encoded)
            while remaining:
                sent = self.stream.write(remaining)
                if not sent:
                    raise IOError("serial write made no progress")
                remaining = remaining[sent:]
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                data = self.stream.read(max(1, min(4096, getattr(self.stream, "in_waiting", 0))))
                for reply in self.decoder.feed(data):
                    if (reply.transfer_id, reply.seq) != (packet.transfer_id, packet.seq):
                        continue
                    if reply.cmd == ERROR:
                        code = reply.payload[0] if reply.payload else 0
                        raise ProtocolError(f"FPGA error {code}: {ERRORS.get(code, 'unspecified')}")
                    if reply.cmd == packet.cmd | 0x80 and len(reply.payload) == expected_length:
                        return reply
        raise TimeoutError(f"no valid reply to cmd={packet.cmd:02x}, seq={packet.seq} after {self.attempts} attempts")

    def ping(self) -> bytes:
        payload = self.transact(Packet(PING), 8).payload
        if payload[:5] != b"UIMG\x01" or struct.unpack_from("<H", payload, 6)[0] != MAX_PAYLOAD:
            raise ProtocolError("incompatible FPGA protocol/capabilities")
        return payload

    def transfer(self, data: bytes, width: int, height: int, mode: int,
                 progress=None, chunk_size: int = 1024, transfer_id: int | None = None) -> bytes:
        if not (1 <= width <= MAX_WIDTH and 1 <= height <= MAX_HEIGHT):
            raise ValueError(f"dimensions must be within 1..{MAX_WIDTH} by 1..{MAX_HEIGHT}")
        if len(data) != width * height * 2 or mode not in MODES.values():
            raise ValueError("invalid RGB565 image or processing mode")
        if not (2 <= chunk_size <= MAX_PAYLOAD) or chunk_size % 2:
            raise ValueError("chunk size must be even and within 2..1024")
        if mode in FILTER_MODES and chunk_size < 20:
            raise ValueError("filter chunk size must be even and within 20..1024")
        capabilities = self.ping()
        if not capabilities[5] & (1 << mode):
            raise ProtocolError("当前 FPGA 固件不支持所选算法，请下载新版 uart_img.bit")
        tid = transfer_id if transfer_id is not None else secrets.randbelow(65535) + 1
        self.transact(Packet(START, tid, 0, struct.pack("<HHBB", width, height, 1, mode)), 0)
        result = bytearray()
        seq = 1
        if mode in FILTER_MODES:
            chunks = iter_filter_tiles(data, width, height, chunk_size)
        else:
            chunks = ((data[offset:offset + chunk_size], min(chunk_size, len(data) - offset))
                      for offset in range(0, len(data), chunk_size))
        for chunk, expected_length in chunks:
            result.extend(self.transact(Packet(DATA, tid, seq, chunk), expected_length).payload)
            seq = (seq + 1) & 0xFFFF
            if progress:
                progress(len(result), len(data))
        self.transact(Packet(END, tid, seq), 0)
        return bytes(result)


def serial_ports():
    from serial.tools import list_ports
    return [(p.device, p.description) for p in list_ports.comports()]


def open_serial(port: str, baud: int):
    import serial
    return serial.Serial(port, baudrate=baud, bytesize=8, parity="N", stopbits=1,
                         timeout=0.03, write_timeout=2, xonxoff=False, rtscts=False, dsrdtr=False)


def main():
    parser = argparse.ArgumentParser(description="FPGA UART RGB565 image client")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("ports", help="list serial ports")
    sub.add_parser("selftest", help="run protocol/reference tests without hardware")
    ping = sub.add_parser("ping")
    send = sub.add_parser("send")
    for p in (ping, send):
        p.add_argument("--port", required=True)
        p.add_argument("--baud", type=int, default=1_500_000)
    send.add_argument("image", type=Path)
    send.add_argument("--width", type=int, help="manual width; omit both dimensions to keep native size")
    send.add_argument("--height", type=int, help="manual height; use together with --width")
    send.add_argument("--mode", choices=MODES, default="gray")
    send.add_argument("--output", type=Path, default=Path("received.png"))
    args = parser.parse_args()
    if args.command == "ports":
        for port, description in serial_ports():
            print(f"{port}: {description}")
    elif args.command == "selftest":
        import unittest
        suite = unittest.defaultTestLoader.discover(str(Path(__file__).parent), pattern="test_*.py")
        if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
            raise SystemExit(1)
    else:
        if args.command == "send":
            source = prepare_image(load_source_image(args.image), args.width, args.height)
            width, height = source.size
            data = image_to_rgb565(source)
        with open_serial(args.port, args.baud) as stream:
            stream.reset_input_buffer()
            client = ImageClient(stream, args.baud)
            if args.command == "ping":
                print("FPGA:", client.ping().hex(" "))
                return
            start = time.monotonic()
            result = client.transfer(data, width, height, MODES[args.mode])
            expected = reference(data, MODES[args.mode], width, height)
            if result != expected:
                raise ProtocolError("received pixels differ from the integer reference model")
            rgb565_to_image(result, width, height).save(args.output)
            print(f"PASS: {width}x{height}, {len(result)} bytes, {time.monotonic()-start:.3f}s, retries={client.retry_count}, saved {args.output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, ProtocolError, TimeoutError) as exc:
        raise SystemExit(str(exc)) from exc
