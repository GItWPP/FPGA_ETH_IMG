"""Generate independent host packets and expected wire replies for XSim."""
from pathlib import Path
import struct
import random
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from uart_image import (Packet, reference, process_pixel, filter_kernel, iter_filter_tiles,
                        PING, START, DATA, END)

OUT = Path(__file__).resolve().parent / "vectors"
OUT.mkdir(exist_ok=True)
actions, expected, labels = [], bytearray(), []


def op(code, value=0):
    actions.append((code << 24) | value)


def raw(data):
    for byte in data:
        op(0, byte)


def case(label):
    labels.append(label)
    op(5, len(labels))


def transaction(request, response=None):
    raw(request.encode())
    if response is not None:
        expected.extend(response.encode())
        op(1, len(expected))
        op(2, 100)  # Last stop bit and control handshake settle.
    else:
        op(2, 55_000)  # > 1ms inter-byte timeout in the simulation DUT.


def ack(request, payload=b""):
    transaction(request, Packet(request.cmd | 0x80, request.transfer_id, request.seq, payload))


def error(request, code):
    transaction(request, Packet(0xFF, request.transfer_id, request.seq, bytes([code])))


def start(tid, width, height, mode):
    return Packet(START, tid, 0, struct.pack("<HHBB", width, height, 1, mode))


case("noise, false start and PING")
raw(b"\x00\xff\x55\x55\x12")
op(7, 100)  # false start: 100 ns, much shorter than half a bit
op(2, 100)
ping = Packet(PING)
ping_payload = b"UIMG\x01\xff\x00\x04"
ack(ping, ping_payload)

case("bad CRC, invalid version, oversize and truncated header recovery")
bad = bytearray(ping.encode())
bad[-1] ^= 1
raw(bad)
op(2, 55_000)
bad = bytearray(ping.encode())
bad[4] = 2
raw(bad)
op(2, 55_000)
raw(bytes.fromhex("55 aa 5a a5 01 03 44 00 01 00 01 04"))
op(2, 55_000)
raw(ping.encode()[:9])
op(2, 55_000)
ack(ping, ping_payload)

case("framing error abort and PING recovery")
raw(ping.encode()[:6])
op(4, 0x12)  # UART byte with low stop bit
op(2, 55_000)
ack(ping, ping_payload)

case("independent host baud +2 percent")
op(6, 653_595)  # bit period in ps: 1.53 Mbps
ack(ping, ping_payload)
case("independent host baud -2 percent")
op(6, 680_272)  # 1.47 Mbps
ack(ping, ping_payload)
op(6, 666_667)

case("invalid command, no session and START parameters")
error(Packet(0x19, 7, 2), 1)
error(Packet(DATA, 7, 1, b"\x00\x00"), 3)
for request in (start(7, 0, 1, 0), start(8, 1921, 1, 0), start(9, 1, 1081, 0),
                start(10, 1, 1, 8), Packet(START, 11, 0, struct.pack("<HHBB", 1, 1, 2, 0))):
    error(request, 2)

case("1920x1080 START accepted and premature END rejected")
ack(start(70, 1920, 1080, 1))
error(Packet(END, 70, 1), 5)

for mode in (0, 1, 2, 6):
    tid = 100 + mode
    case(f"mode {mode}: full block, short block, retries and END")
    s = start(tid, 320, 2, mode)  # 640 pixels / 1280 bytes
    ack(s)
    ack(s)  # START ACK was lost
    error(start(tid, 319, 2, mode), 6)
    error(Packet(END, tid, 1), 5)  # too early
    error(Packet(DATA, tid, 2, b"\x00\x00"), 4)
    error(Packet(DATA, tid, 1, b"\x00"), 5)
    error(Packet(DATA, tid, 1, b""), 5)
    error(Packet(DATA, tid + 10, 1, b"\x00\x00"), 3)
    pixels = [((i * 937 + mode * 101) ^ (i << 5)) & 65535 for i in range(640)]
    pixels[:8] = [0, 65535, 0xF800, 0x07E0, 0x001F, 0xAA55, 0xA55A, 0x1234]
    image = struct.pack("<640H", *pixels)
    first = Packet(DATA, tid, 1, image[:1024])
    bad = bytearray(first.encode())
    bad[100] ^= 0x80
    raw(bad)
    op(2, 55_000)
    ack(first, reference(first.payload, mode))
    # Error reply must not destroy the successful cached pixel block.
    error(Packet(DATA, tid, 3, b"\x00\x00"), 4)
    error(Packet(DATA, tid, 1, b"\x00\x00"), 6)
    ack(first, reference(first.payload, mode))
    last = Packet(DATA, tid, 2, image[1024:])
    ack(last, reference(last.payload, mode))
    error(Packet(DATA, tid, 3, b"\x00\x00"), 5)  # exceeds total
    end = Packet(END, tid, 3)
    ack(end)
    ack(end)  # END ACK was lost
    error(Packet(DATA, tid, 4, b"\x00\x00"), 3)

case("single pixel and reset during partial request")
ack(start(200, 1, 1, 1))
ack(Packet(DATA, 200, 1, b"\x00\xf8"), reference(b"\x00\xf8", 1))
ack(Packet(END, 200, 2))
raw(start(201, 1, 1, 0).encode()[:15])
op(3)
op(2, 200)
error(Packet(DATA, 201, 1, b"\x00\x00"), 3)
ack(start(202, 1, 1, 2))
ack(Packet(DATA, 202, 1, b"\x55\xaa"), reference(b"\x55\xaa", 2))
ack(Packet(END, 202, 2))

case("reset during processing, then new START")
ack(start(210, 320, 2, 1))
raw(Packet(DATA, 210, 1, image[:1024]).encode())
op(3)
op(2, 200)
ack(start(211, 1, 1, 0))
ack(Packet(DATA, 211, 1, b"\xaa\x55"), b"\xaa\x55")
ack(Packet(END, 211, 2))

for mode in (3, 4, 5, 7):
    case(f"filter {mode}: cross-tile rows, malformed length/count, retries and borders")
    width, height, tid = 169, 2, 300 + mode
    image = struct.pack(f"<{width * height}H", *[((i * 701) ^ (i << 7)) & 65535 for i in range(width * height)])
    wanted = reference(image, mode, width, height)
    ack(start(tid, width, height, mode))
    for count in (0, 169, 65535):
        error(Packet(DATA, tid, 1, struct.pack("<H", count) + bytes(18)), 5)
    tiles = list(iter_filter_tiles(image, width, height))
    error(Packet(DATA, tid, 1, tiles[0][0][:-2]), 5)
    cursor = 0
    for seq, (payload, output_length) in enumerate(tiles, 1):
        request = Packet(DATA, tid, seq, payload)
        reply = wanted[cursor:cursor + output_length]
        ack(request, reply)
        if seq == 1:
            # Remaining row width is one; a two-output tile must not cross rows.
            error(Packet(DATA, tid, seq + 1, struct.pack("<H", 2) + bytes(24)), 5)
            error(start(tid + 20, 1, 1, 8), 2)
            error(Packet(DATA, tid, seq, payload[:-2]), 6)
            ack(request, reply)
        cursor += output_length
    error(Packet(DATA, tid, len(tiles) + 1, struct.pack("<H", 1) + bytes(18)), 5)
    ack(Packet(END, tid, len(tiles) + 1))
    ack(Packet(END, tid, len(tiles) + 1))

    for width, height in ((1, 1), (1, 3), (9, 1)):
        tid += 10
        case(f"filter {mode}: degenerate native image {width}x{height}")
        image = struct.pack(f"<{width * height}H", *[(i * 1234 + 0x1234) & 65535 for i in range(width * height)])
        wanted = reference(image, mode, width, height)
        ack(start(tid, width, height, mode))
        cursor = 0
        for seq, (payload, output_length) in enumerate(iter_filter_tiles(image, width, height), 1):
            ack(Packet(DATA, tid, seq, payload), wanted[cursor:cursor + output_length])
            cursor += output_length
        ack(Packet(END, tid, seq + 1))

op(2, 100_000)

with (OUT / "stimulus.txt").open("w", encoding="ascii") as f:
    f.write(f"{len(actions)} {len(expected)}\n")
    f.writelines(f"{word:08x}\n" for word in actions)
(OUT / "expected.hex").write_text("".join(f"{b:02x}\n" for b in expected), encoding="ascii")
(OUT / "gray.hex").write_text("".join(f"{process_pixel(p, 1):04x}\n" for p in range(65536)), encoding="ascii")
(OUT / "gamma.hex").write_text("".join(f"{process_pixel(p, 6):04x}\n" for p in range(65536)), encoding="ascii")
(OUT / "cases.txt").write_text("\n".join(f"{i+1}: {label}" for i, label in enumerate(labels)) + "\n", encoding="utf-8")
randomizer = random.Random(20261021)
windows = [[color] * 9 for color in (0, 65535, 0xF800, 0x07E0, 0x001F, 0x1234)]
windows += [[0x4529] * 4 + [noise] + [0x4529] * 4 for noise in (0, 65535)]
windows += [[0xF800] * 3 + [0x07E0] * 3 + [0x001F] * 3]
windows += [list(range(9)), list(reversed(range(9))), [0, 0, 4 << 5] * 3]
windows += [[randomizer.randrange(65536) for _ in range(9)] for _ in range(256)]
windows += [[randomizer.randrange(8) << 5 for _ in range(9)] for _ in range(256)]
kernel_lines = []
for mode in (3, 4, 5, 7):
    for window in windows:
        packed = sum(pixel << (16 * index) for index, pixel in enumerate(window))
        kernel_lines.append(f"{mode} {filter_kernel(window, mode):04x} {packed:036x}\n")
(OUT / "kernels.txt").write_text(str(len(kernel_lines)) + "\n" + "".join(kernel_lines), encoding="ascii")
print(f"Generated {len(actions)} stimulus events, {len(expected)} reply bytes, 65536 gray values, {len(kernel_lines)} kernels; {len(labels)} cases")
