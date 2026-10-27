import struct
import time
import unittest
from uart_image import (Packet, Decoder, ImageClient, ProtocolError, crc16, reference,
                        process_pixel, PING, START, DATA, END)


class RetryStream:
    """Device stub drops the first result; an identical retry returns its cached result."""
    def __init__(self, nack=False):
        self.rx = bytearray()
        self.requests = []
        self.cache = None
        self.unique_data = 0
        self.nack = nack

    @property
    def in_waiting(self):
        return len(self.rx)

    def reset_input_buffer(self):
        self.rx.clear()

    def write(self, data):
        request = Decoder().feed(bytes(data))[0]
        self.requests.append(request)
        if self.nack:
            reply = Packet(0xFF, request.transfer_id, request.seq, b"\x04")
        elif request.cmd == PING:
            reply = Packet(0x81, request.transfer_id, request.seq, b"UIMG\x01\x07\x00\x04")
        elif request.cmd == DATA:
            if self.cache != request:
                self.cache = request
                self.unique_data += 1
                return len(data)
            reply = Packet(0x83, request.transfer_id, request.seq, reference(request.payload, 1))
        else:
            reply = Packet(request.cmd | 0x80, request.transfer_id, request.seq)
        self.rx.extend(reply.encode())
        return len(data)

    def read(self, size):
        if not self.rx:
            time.sleep(0.001)
        data = bytes(self.rx[:size])
        del self.rx[:size]
        return data


class ProtocolTests(unittest.TestCase):
    def test_crc_known_vector(self):
        self.assertEqual(crc16(b"123456789"), 0x29B1)

    def test_wire_layout(self):
        encoded = Packet(3, 0x1234, 0x5678, b"\x00\xf8").encode()
        self.assertEqual(encoded[:14], bytes.fromhex("55 aa 5a a5 01 03 34 12 78 56 02 00 00 f8"))

    def test_fragmented_and_coalesced_packets(self):
        packets = [Packet(PING), Packet(DATA, 42, 1, bytes(range(256)) * 4)]
        wire = b"garbage\x55\x55" + b"".join(p.encode() for p in packets)
        for stride in (1, 2, 3, 7, 1024, 4096):
            decoder, decoded = Decoder(), []
            for i in range(0, len(wire), stride):
                decoded.extend(decoder.feed(wire[i:i + stride]))
            self.assertEqual(decoded, packets)

    def test_corruption_and_invalid_length_resync(self):
        good = Packet(PING).encode()
        bad = bytearray(Packet(DATA, 1, 2, b"\x55\xaa\x5a\xa5").encode())
        bad[-1] ^= 1
        oversized = bytes.fromhex("55 aa 5a a5 01 03 01 00 01 00 01 04")
        decoder = Decoder()
        self.assertEqual(decoder.feed(bytes(bad) + oversized + good), [Packet(PING)])
        self.assertGreater(decoder.bad_crc, 0)

    def test_model_boundaries(self):
        self.assertEqual(process_pixel(0, 1), 0)
        self.assertEqual(process_pixel(0xFFFF, 1), 0xFFFF)
        self.assertEqual(process_pixel(0xF800, 1), 0x4A69)
        data = struct.pack("<6H", 0, 0xFFFF, 0xF800, 0x07E0, 0x001F, 0x55AA)
        self.assertEqual(reference(data, 0), data)
        self.assertEqual(reference(reference(data, 2), 2), data)
        with self.assertRaises(ValueError):
            reference(b"\x00", 1)

    def test_retry_reuses_exact_request(self):
        stream = RetryStream()
        client = ImageClient(stream)
        data = struct.pack("<3H", 0xF800, 0x07E0, 0x001F)
        self.assertEqual(client.transfer(data, 3, 1, 1, transfer_id=42), reference(data, 1))
        self.assertEqual(client.retry_count, 1)
        self.assertEqual(stream.unique_data, 1)
        requests = [p for p in stream.requests if p.cmd == DATA]
        self.assertEqual(requests[0], requests[1])

    def test_nack_is_reported_without_retry(self):
        stream = RetryStream(nack=True)
        with self.assertRaisesRegex(ProtocolError, "unexpected sequence"):
            ImageClient(stream).transact(Packet(DATA, 1, 1, b"\x00\x00"), 2)
        self.assertEqual(len(stream.requests), 1)

    def test_image_argument_validation(self):
        client = ImageClient(RetryStream())
        for width, height, data, mode in [(0, 1, b"", 0), (1921, 1, b"", 0), (1, 1081, b"", 0), (1, 1, b"", 0), (1, 1, b"00", 8)]:
            with self.assertRaises(ValueError):
                client.transfer(data, width, height, mode)

    def test_1080p_host_full_length_and_sequence(self):
        class ImmediateStream(RetryStream):
            def __init__(self):
                super().__init__()
                self.data_count = 0
                self.byte_count = 0
                self.start_dimensions = None
                self.end_seq = None

            def write(self, data):
                request = Decoder().feed(bytes(data))[0]
                if request.cmd == PING:
                    payload = b"UIMG\x01\x07\x00\x04"
                elif request.cmd == START:
                    self.start_dimensions = struct.unpack("<HHBB", request.payload)
                    payload = b""
                elif request.cmd == DATA:
                    self.data_count += 1
                    self.byte_count += len(request.payload)
                    if request.seq != self.data_count:
                        raise AssertionError("incorrect full-frame sequence")
                    payload = request.payload
                elif request.cmd == END:
                    self.end_seq = request.seq
                    payload = b""
                else:
                    raise AssertionError("unexpected command")
                self.rx.extend(Packet(request.cmd | 0x80, request.transfer_id, request.seq, payload).encode())
                return len(data)

        stream = ImmediateStream()
        data = bytes(1920 * 1080 * 2)
        progress = []
        result = ImageClient(stream).transfer(data, 1920, 1080, 0,
                                             progress=lambda done, total: progress.append((done, total)))
        self.assertEqual(result, data)
        self.assertEqual(stream.start_dimensions, (1920, 1080, 1, 0))
        self.assertEqual((stream.data_count, stream.byte_count, stream.end_seq), (4050, 4147200, 4051))
        self.assertEqual(progress[-1], (4147200, 4147200))


if __name__ == "__main__":
    unittest.main(verbosity=2)
