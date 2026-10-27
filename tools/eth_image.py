"""ZU4EV UDP image client. Every datagram contains exactly one complete packet."""
from __future__ import annotations

import argparse
import ipaddress
import heapq
import select
import socket
import secrets
import struct
from collections import deque
from pathlib import Path
import time

from uart_image import (DATA, END, START, FILTER_MODES, Decoder, ERRORS, ERROR, ImageClient,
                        MAX_HEIGHT, MAX_WIDTH, MAX_PAYLOAD, MODES, iter_filter_tiles,
                        MAGIC, VERSION, HEADER, crc16,
                        Packet, ProtocolError, load_source_image,
                        prepare_image, reference)
from rgb565_codec import encode_rgb565 as image_to_rgb565, decode_rgb565 as rgb565_to_image

DEFAULT_HOST = '192.168.1.12'
DEFAULT_PORT = 1234
LINK_BITS_PER_SECOND = 1_000_000_000
WINDOW_INFO = 5
MAX_WINDOW = 64
DEFAULT_WINDOW = 32


class TransferCancelled(RuntimeError):
    """The caller stopped an in-flight frame; the next session must START again."""


def network_endpoint(host, port):
    address = str(ipaddress.IPv4Address(host.strip()))
    port = int(port)
    if not 1 <= port <= 65535:
        raise ValueError('UDP端口范围为1～65535')
    if ipaddress.IPv4Address(address).is_multicast or address in ('0.0.0.0', '255.255.255.255'):
        raise ValueError('请输入板卡的单播IPv4地址')
    return address, port


class UdpImageClient(ImageClient):
    """Reuse commands/algorithms while keeping datagrams isolated and retryable."""
    def __init__(self, host=DEFAULT_HOST, port=DEFAULT_PORT, *, bind_ip='',
                 attempts=3, timeout=0.5, window_size=DEFAULT_WINDOW, cancel_event=None):
        if attempts < 1 or timeout <= 0:
            raise ValueError('attempts and timeout must be positive')
        if not 1 <= window_size <= MAX_WINDOW:
            raise ValueError('window_size must be within 1..64')
        self.peer = network_endpoint(host, port)
        self.native_stream = True
        self.stream_backend = 'python'
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
            self.socket.bind((bind_ip, 0))
            # The OS also filters unsolicited datagrams from other endpoints.
            self.socket.connect(self.peer)
        except BaseException:
            self.socket.close()
            raise
        self.attempts = attempts
        self.timeout = timeout
        self.baud = LINK_BITS_PER_SECOND
        self.retry_count = 0
        self.bad_datagrams = 0
        self.sent_datagrams = 0
        self.window_size = window_size
        self.active_window = 1
        self.window_peak = 0
        self._window_negotiated = False
        self.cancel_event = cancel_event

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        self.close()

    def close(self):
        self.socket.close()

    def _check_cancelled(self):
        if self.cancel_event is not None and self.cancel_event.is_set():
            raise TransferCancelled('已停止视频传输')

    def _decode_datagram(self, data, source):
        if source != self.peer:
            return None
        # An Ethernet datagram must be exactly one packet. No resync scan,
        # incremental buffer, re-encoding, or second receive-side CRC pass.
        size = len(data)
        if not 14 <= size <= MAX_PAYLOAD+14 or data[:4] != MAGIC:
            self.bad_datagrams += 1
            return None
        version,cmd,tid,seq,length = HEADER.unpack_from(data,4)
        if version != VERSION or length > MAX_PAYLOAD or size != length+14:
            self.bad_datagrams += 1
            return None
        if crc16(data[4:-2]) != (data[-2] | (data[-1] << 8)):
            self.bad_datagrams += 1
            return None
        return Packet(cmd,tid,seq,data[12:-2])

    def _send_datagram(self, encoded):
        self._check_cancelled()
        deadline = time.monotonic()+self.timeout
        while True:
            try:
                count = self.socket.send(encoded)
                break
            except BlockingIOError:
                self._check_cancelled()
                remaining = deadline-time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('UDP发送缓冲区等待超时')
                select.select([], [self.socket], [], min(remaining,0.05))
        if count != len(encoded):
            raise OSError('UDP request was not sent as one complete datagram')
        self.sent_datagrams += 1

    def _negotiate_window(self):
        if self._window_negotiated:
            return
        if self.window_size > 1:
            try:
                capability = self.transact(Packet(WINDOW_INFO), 8).payload
            except ProtocolError as exc:
                # Only an explicit unknown-command response identifies old firmware.
                if str(exc) != 'FPGA error 1: unknown command':
                    raise
            else:
                if capability[:5] != b'EWIN\x01' or not 1 <= capability[5] <= MAX_WINDOW:
                    raise ProtocolError('incompatible FPGA window capabilities')
                if struct.unpack_from('<H', capability, 6)[0] != MAX_PAYLOAD:
                    raise ProtocolError('incompatible FPGA window payload limit')
                self.active_window = min(self.window_size, capability[5])
        self._window_negotiated = True

    def transfer(self, data, width, height, mode, progress=None, chunk_size=1024,
                 transfer_id=None):
        if not (1 <= width <= MAX_WIDTH and 1 <= height <= MAX_HEIGHT):
            raise ValueError(f'dimensions must be within 1..{MAX_WIDTH} by 1..{MAX_HEIGHT}')
        if len(data) != width * height * 2 or mode not in MODES.values():
            raise ValueError('invalid RGB565 image or processing mode')
        if not 2 <= chunk_size <= MAX_PAYLOAD or chunk_size % 2:
            raise ValueError('chunk size must be even and within 2..1024')
        if mode in FILTER_MODES and chunk_size < 20:
            raise ValueError('filter chunk size must be even and within 20..1024')
        capabilities = self.ping()
        if not capabilities[5] & (1 << mode):
            raise ProtocolError('当前 FPGA 固件不支持所选算法')
        self._negotiate_window()
        tid = transfer_id if transfer_id is not None else secrets.randbelow(65535) + 1
        self.transact(Packet(START, tid, 0, struct.pack('<HHBB', width, height, 1, mode)), 0)
        if mode in FILTER_MODES:
            chunks = iter_filter_tiles(data, width, height, chunk_size)
        else:
            chunks = ((data[offset:offset+chunk_size], min(chunk_size, len(data)-offset))
                      for offset in range(0, len(data), chunk_size))
        result, next_seq = self._transfer_window(chunks, tid, len(data), progress)
        self.transact(Packet(END, tid, next_seq), 0)
        return result

    def transfer_sobel_stream(self, rgb565, width, height, *, padded=False, progress=None):
        """FPGA streaming Sobel: RGB565 in, exact GRAY8 out; no host filtering."""
        from stream_sobel import pad_rgb565,iter_stream_chunks
        if not (1 <= width <= MAX_WIDTH and 1 <= height <= MAX_HEIGHT):
            raise ValueError('图像尺寸超出1..1920 × 1..1080')
        expected_bytes = 2*(width+1)*(height+1) if padded else 2*width*height
        if len(rgb565) != expected_bytes:
            raise ValueError('RGB565字节数与流式图像尺寸不一致')
        payload = rgb565 if padded else pad_rgb565(rgb565,width,height)
        self._negotiate_window()
        tid = secrets.randbelow(65535)+1
        header = struct.pack('<HHBB',width,height,1,5)
        reply = self.transact(Packet(0x40,tid,0,header),8)
        if reply.payload != b'SBL1'+struct.pack('<HH',width,height):
            raise ProtocolError('流式Sobel固件版本或尺寸应答不匹配')
        native_result = None
        if self.native_stream:
            from native_stream import exchange
            native_result = exchange(self,payload,width,height,tid,progress)
        if native_result is None:
            result,seq = self._transfer_window(iter_stream_chunks(payload,width,height),tid,
                                               width*height,progress,data_command=0x41)
            self.stream_backend = 'python'
        else:
            result,seq = native_result
            self.stream_backend = 'native_udp' 
        end = self.transact(Packet(0x42,tid,seq),4)
        if struct.unpack('<I',end.payload)[0] != width*height:
            raise ProtocolError('FPGA流式Sobel输出像素计数不匹配')
        return result

    def _transfer_window(self, chunks, tid, total, progress, *, data_command=DATA):
        # A received out-of-order reply still occupies its cache slot until
        # the head is acknowledged. Deadlines are ordered independently.
        pending = deque()
        by_seq = {}
        deadlines = []
        generation = 0
        iterator = iter(chunks)
        exhausted = False
        seq = 1
        result = bytearray(total)
        committed = 0
        progress_time = 0.0
        previous_timeout = self.socket.gettimeout()
        self.socket.setblocking(False)
        try:
            while pending or not exhausted:
                self._check_cancelled()
                while len(pending) < self.active_window and not exhausted:
                    try:
                        payload,expected = next(iterator)
                    except StopIteration:
                        exhausted = True
                        break
                    encoded = Packet(data_command,tid,seq,payload).encode()
                    self._send_datagram(encoded)
                    deadline = time.monotonic()+self.timeout
                    entry = dict(seq=seq,expected=expected,encoded=encoded,
                                 reply=None,attempts=1,deadline=deadline)
                    pending.append(entry)
                    by_seq[seq] = entry
                    heapq.heappush(deadlines,(deadline,generation,entry))
                    generation += 1
                    self.window_peak = max(self.window_peak,len(pending))
                    seq = (seq+1) & 0xffff
                if not pending:
                    break
                # Acknowledged entries and superseded retry deadlines are
                # removed only when they reach the heap head.
                while deadlines:
                    deadline,_,entry = deadlines[0]
                    if entry['reply'] is not None or entry['deadline'] != deadline:
                        heapq.heappop(deadlines)
                        continue
                    if deadline > time.monotonic():
                        break
                    heapq.heappop(deadlines)
                    if entry['attempts'] >= self.attempts:
                        raise TimeoutError(f'窗口传输超时：序号 {entry["seq"]}，已尝试 {self.attempts} 次')
                    self._send_datagram(entry['encoded'])
                    entry['attempts'] += 1
                    entry['deadline'] = time.monotonic()+self.timeout
                    heapq.heappush(deadlines,(entry['deadline'],generation,entry))
                    generation += 1
                    self.retry_count += 1
                try:
                    data,source = self.socket.recvfrom(65535)
                except BlockingIOError:
                    remaining = max(0.0,deadlines[0][0]-time.monotonic())
                    if self.cancel_event is not None:
                        remaining = min(remaining,0.05)
                    select.select([self.socket], [], [], remaining)
                    continue
                except ConnectionResetError:
                    continue
                reply = self._decode_datagram(data,source)
                if reply is None or reply.transfer_id != tid or reply.seq not in by_seq:
                    continue
                entry = by_seq[reply.seq]
                if reply.cmd == ERROR:
                    code = reply.payload[0] if reply.payload else 0
                    if code == 4:
                        continue
                    raise ProtocolError(f'FPGA error {code}: {ERRORS.get(code,"unspecified")}')
                if reply.cmd != data_command | 0x80 or len(reply.payload) != entry['expected']:
                    continue
                entry['reply'] = reply.payload
                while pending and pending[0]['reply'] is not None:
                    done = pending.popleft()
                    del by_seq[done['seq']]
                    end = committed+len(done['reply'])
                    if end > total:
                        raise ProtocolError('回传图像超过预期长度')
                    result[committed:end] = done['reply']
                    committed = end
                now = time.monotonic()
                if progress and (now-progress_time >= 0.02 or committed == total):
                    progress(committed,total)
                    progress_time = now
        finally:
            self.socket.settimeout(previous_timeout)
        if committed != total:
            raise ProtocolError('回传图像长度不完整')
        return bytes(result),seq

    def transact(self, packet: Packet, expected_length: int, *, timeout=None) -> Packet:
        encoded = packet.encode()
        if not 0 <= expected_length <= MAX_PAYLOAD:
            raise ValueError('expected payload length must be within 0..1024')
        interval = self.timeout if timeout is None else timeout
        if interval <= 0:
            raise ValueError('timeout must be positive')
        for attempt in range(self.attempts):
            self._check_cancelled()
            if attempt:
                self.retry_count += 1
            self._send_datagram(encoded)
            deadline = time.monotonic() + interval
            while (remaining := deadline - time.monotonic()) > 0:
                self._check_cancelled()
                self.socket.settimeout(min(remaining, 0.05) if self.cancel_event is not None else remaining)
                try:
                    data, source = self.socket.recvfrom(65535)
                except socket.timeout:
                    if self.cancel_event is not None:
                        continue
                    break
                except ConnectionResetError:
                    # Windows may report an ICMP unreachable from a stale PL image.
                    continue
                reply = self._decode_datagram(data, source)
                if reply is None:
                    continue
                if (reply.transfer_id, reply.seq) != (packet.transfer_id, packet.seq):
                    continue
                if reply.cmd == ERROR:
                    code = reply.payload[0] if reply.payload else 0
                    raise ProtocolError(f'FPGA error {code}: {ERRORS.get(code, "unspecified")}')
                if reply.cmd == packet.cmd | 0x80 and len(reply.payload) == expected_length:
                    return reply
        raise TimeoutError(f'{self.peer[0]}:{self.peer[1]} 无有效回复，命令{packet.cmd:02X}、'
                           f'序号{packet.seq}，已尝试{self.attempts}次；请检查千兆链路、IP及bitstream')


def main():
    parser = argparse.ArgumentParser(description='ZU4EV千兆以太网图像客户端')
    parser.add_argument('command', choices=('ping', 'send', 'selftest'))
    parser.add_argument('image', type=Path, nargs='?')
    parser.add_argument('--host', default=DEFAULT_HOST)
    parser.add_argument('--port', type=int, default=DEFAULT_PORT)
    parser.add_argument('--bind-ip', default='')
    parser.add_argument('--mode', choices=MODES, default='gray')
    parser.add_argument('--width', type=int)
    parser.add_argument('--height', type=int)
    parser.add_argument('--output', type=Path, default=Path('received.png'))
    args = parser.parse_args()
    if args.command == 'selftest':
        import unittest
        suite = unittest.defaultTestLoader.discover(str(Path(__file__).parent), pattern='test_*.py')
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    with UdpImageClient(args.host, args.port, bind_ip=args.bind_ip) as client:
        if args.command == 'ping':
            print('PASS UDP:', client.peer, client.ping().hex(' '))
            return 0
        if args.image is None:
            parser.error('send requires an image path')
        source = prepare_image(load_source_image(args.image), args.width, args.height)
        width, height = source.size
        pixels = image_to_rgb565(source)
        start = time.monotonic()
        result = client.transfer(pixels, width, height, MODES[args.mode])
        elapsed = time.monotonic() - start
        if result != reference(pixels, MODES[args.mode], width, height):
            raise ProtocolError('FPGA pixels differ from the integer reference')
        rgb565_to_image(result, width, height).save(args.output)
        print(f'PASS {width}x{height}, {elapsed:.3f}s, retries={client.retry_count}, saved={args.output}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
