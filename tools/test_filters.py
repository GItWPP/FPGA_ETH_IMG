"""Neighborhood math, native-size borders, packet packing and firmware negotiation."""
import random
import struct
import unittest

from uart_image import (DATA, END, PING, START, Decoder, ImageClient, Packet, ProtocolError,
                        filter_kernel, gray565, iter_filter_tiles, reference)


class FilterTests(unittest.TestCase):
    def test_constant_color_and_single_pixel(self):
        for width, height in ((1, 1), (1, 9), (11, 1), (7, 5)):
            for color in (0, 0xFFFF, 0xF800, 0x07E0, 0x001F, 0x1234):
                data = struct.pack("<H", color) * (width * height)
                for mode in (3, 4):
                    self.assertEqual(reference(data, mode, width, height), data)
                self.assertEqual(reference(data, 5, width, height), bytes(len(data)))

    def test_mean_rounds_each_native_channel_down(self):
        window = [0] * 8 + [0xFFFF]
        self.assertEqual(filter_kernel(window, 3), (3 << 11) | (7 << 5) | 3)

    def test_color_median_removes_salt_and_pepper(self):
        for noise in (0, 0xFFFF):
            self.assertEqual(filter_kernel([0x4529] * 8 + [noise], 4), 0x4529)
        # Independent per-channel medians need not equal any one input pixel.
        self.assertEqual(filter_kernel([0xF800] * 3 + [0x07E0] * 3 + [0x001F] * 3, 4), 0)

    def test_sobel_polarity_saturation_and_signed_gradients(self):
        # Grayscale of RGB565 with R5=B5=0, G6=4 is 9. Vertical step has |Gx|=36.
        stripe = [0, 0, 4 << 5] * 3
        self.assertEqual(filter_kernel(stripe, 5), gray565(36))
        self.assertEqual(filter_kernel(list(reversed(stripe)), 5), gray565(36))
        self.assertEqual(filter_kernel([0, 0, 0xFFFF] * 3, 5), 0xFFFF)
        # Opposite X/Y signs must add magnitudes rather than cancel.
        diagonal = [0xFFFF, 0xFFFF, 0xFFFF, 0, 0, 0xFFFF, 0, 0, 0]
        self.assertEqual(filter_kernel(diagonal, 5), 0xFFFF)

    def test_tiles_preserve_neighbors_across_every_boundary(self):
        randomizer = random.Random(123)
        for width, height in ((1, 1), (1, 7), (9, 1), (17, 5), (169, 3), (321, 2), (1920, 1)):
            pixels = [randomizer.randrange(65536) for _ in range(width * height)]
            data = struct.pack(f"<{len(pixels)}H", *pixels)
            for capacity in (20, 64, 1024):
                cursor = 0
                for payload, output_length in iter_filter_tiles(data, width, height, capacity):
                    count, = struct.unpack_from("<H", payload)
                    self.assertEqual(output_length, count * 2)
                    self.assertEqual(len(payload), count * 6 + 14)
                    self.assertLessEqual(len(payload), capacity)
                    y, x = divmod(cursor, width)
                    self.assertLessEqual(x + count, width)
                    neighbors = list(struct.unpack(f"<{3 * (count + 2)}H", payload[2:]))
                    wanted = [pixels[min(height - 1, max(0, row)) * width + min(width - 1, max(0, col))]
                              for row in (y - 1, y, y + 1) for col in range(x - 1, x + count + 1)]
                    self.assertEqual(neighbors, wanted)
                    cursor += count
                self.assertEqual(cursor, width * height)

    def test_filter_requires_dimensions(self):
        with self.assertRaisesRegex(ValueError, "dimensions"):
            reference(b"\x00\x00", 3)
        for capacity in (0, 19, 1025):
            with self.assertRaises(ValueError):
                list(iter_filter_tiles(b"\x00\x00", 1, 1, capacity))

    def test_old_firmware_rejected_before_start(self):
        class OldClient(ImageClient):
            def ping(self):
                return b"UIMG\x01\x07\x00\x04"

            def transact(self, packet, expected_length):
                raise AssertionError("must reject unsupported filter before START")

        with self.assertRaisesRegex(ProtocolError, "固件"):
            OldClient(None).transfer(b"\x00\x00", 1, 1, 3)

    def test_client_uses_output_lengths_and_reassembles_rows(self):
        class FilterStream:
            def __init__(self):
                self.rx = bytearray()
                self.mode = None
                self.requests = []

            @property
            def in_waiting(self):
                return len(self.rx)

            def reset_input_buffer(self):
                self.rx.clear()

            def write(self, data):
                packet, = Decoder().feed(bytes(data))
                self.requests.append(packet)
                if packet.cmd == PING:
                    payload = b"UIMG\x01\x3f\x00\x04"
                elif packet.cmd == START:
                    self.mode = packet.payload[5]
                    payload = b""
                elif packet.cmd == DATA:
                    count, = struct.unpack_from("<H", packet.payload)
                    pixels = struct.unpack(f"<{3 * (count + 2)}H", packet.payload[2:])
                    values = [filter_kernel([pixels[row * (count + 2) + x + col]
                                             for row in range(3) for col in range(3)], self.mode)
                              for x in range(count)]
                    payload = struct.pack(f"<{count}H", *values)
                elif packet.cmd == END:
                    payload = b""
                else:
                    raise AssertionError("unexpected command")
                self.rx.extend(Packet(packet.cmd | 0x80, packet.transfer_id, packet.seq, payload).encode())
                return len(data)

            def read(self, count):
                result = bytes(self.rx[:count])
                del self.rx[:count]
                return result

        width, height = 173, 3
        data = struct.pack(f"<{width * height}H", *[(i * 937) & 65535 for i in range(width * height)])
        for mode in (3, 4, 5):
            stream = FilterStream()
            progress = []
            result = ImageClient(stream).transfer(data, width, height, mode,
                                                 progress=lambda done, total: progress.append((done, total)))
            self.assertEqual(result, reference(data, mode, width, height))
            packets = [p for p in stream.requests if p.cmd == DATA]
            self.assertEqual([p.seq for p in packets], list(range(1, 7)))
            self.assertEqual(stream.requests[-1].seq, 7)
            self.assertEqual(progress[-1], (len(data), len(data)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
