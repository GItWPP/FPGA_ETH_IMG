"""Exact enhancement math and independent ordinary/neighborhood mode routing."""
import math
import struct
import unittest

from uart_image import (FILTER_MODES, ImageClient, Packet, DATA, END, PING, START,
                        filter_kernel, process_pixel, reference)


class EnhancementTests(unittest.TestCase):
    def test_gamma_preserves_endpoints_and_lifts_channels_monotonically(self):
        self.assertEqual(process_pixel(0, 6), 0)
        self.assertEqual(process_pixel(65535, 6), 65535)
        for shift, maximum in ((11, 31), (5, 63), (0, 31)):
            values = [(process_pixel(value << shift, 6) >> shift) & maximum for value in range(maximum + 1)]
            self.assertEqual(values, sorted(values))
            for source, result in enumerate(values):
                self.assertGreaterEqual(result, source)
                self.assertLessEqual(result * result, source * maximum)
                self.assertGreater((result + 1) ** 2, source * maximum)

    def test_gamma_full_rgb565_domain(self):
        data = struct.pack("<65536H", *range(65536))
        result = struct.unpack("<65536H", reference(data, 6))
        for pixel, value in enumerate(result):
            expected = ((math.isqrt((pixel >> 11) * 31) << 11)
                        | (math.isqrt(((pixel >> 5) & 63) * 63) << 5)
                        | math.isqrt((pixel & 31) * 31))
            self.assertEqual(value, expected)

    def test_sharpen_constant_color_and_degenerate_borders(self):
        for color in (0, 65535, 0xF800, 0x07E0, 0x001F, 0x1234):
            self.assertEqual(filter_kernel([color] * 9, 7), color)
            for size in ((1, 1), (1, 9), (11, 1), (7, 5)):
                data = struct.pack("<H", color) * (size[0] * size[1])
                self.assertEqual(reference(data, 7, *size), data)

    def test_sharpen_negative_and_positive_clamping_per_channel(self):
        window = [65535] * 9
        window[4] = 0
        self.assertEqual(filter_kernel(window, 7), 0)
        window = [0] * 9
        window[4] = 65535
        self.assertEqual(filter_kernel(window, 7), 65535)
        window = [0] * 9
        window[4] = (2 << 11) | (4 << 5) | 3
        window[1] = (1 << 11) | (2 << 5) | 1
        self.assertEqual(filter_kernel(window, 7), (9 << 11) | (18 << 5) | 14)

    def test_gamma_uses_raw_packets_and_sharpen_uses_neighborhoods(self):
        class InspectClient(ImageClient):
            def __init__(self):
                super().__init__(None)
                self.requests = []

            def ping(self):
                return b"UIMG\x01\xff\x00\x04"

            def transact(self, request, expected_length):
                self.requests.append((request, expected_length))
                return Packet(request.cmd | 0x80, request.transfer_id, request.seq, bytes(expected_length))

        self.assertNotIn(6, FILTER_MODES)
        self.assertIn(7, FILTER_MODES)
        data = struct.pack("<3H", 0x1234, 0x4567, 0x89AB)
        client = InspectClient()
        client.transfer(data, 3, 1, 6)
        packet, length = next((p, n) for p, n in client.requests if p.cmd == DATA)
        self.assertEqual(packet.payload, data)
        self.assertEqual(length, len(data))
        client = InspectClient()
        client.transfer(data, 3, 1, 7)
        packet, length = next((p, n) for p, n in client.requests if p.cmd == DATA)
        self.assertEqual(struct.unpack_from("<H", packet.payload)[0], 3)
        self.assertEqual(len(packet.payload), 32)
        self.assertEqual(length, 6)


if __name__ == "__main__":
    unittest.main(verbosity=2)
