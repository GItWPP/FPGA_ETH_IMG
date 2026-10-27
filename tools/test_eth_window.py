"""Fault-injected end-to-end UDP window tests with a bounded board cache."""
from collections import Counter
import struct
import unittest

from eth_image import UdpImageClient
from test_eth_transport import UdpResponder
from uart_image import Decoder, Packet, ProtocolError, reference


class WindowBoard:
    def __init__(self, raw, width, height, mode=0, *, drop_request=0, drop_reply=0,
                 reorder=False, corrupt=0, old=False, fatal=0, capacity=8):
        self.capacity = capacity
        self.raw = raw
        self.output = reference(raw, mode, width, height)
        self.offset = 0
        self.next_seq = 1
        self.cache = {}
        self.counts = Counter()
        self.executions = Counter()
        self.drop_request = drop_request
        self.drop_reply = drop_reply
        self.reorder = reorder
        self.corrupt = corrupt
        self.old = old
        self.fatal = fatal
        self.held = None
        self.first_count_at_nine = None

    def handle(self, data, count):
        request = Decoder().feed(data)[0]
        cmd, tid, seq = request.cmd, request.transfer_id, request.seq
        def reply(command, payload=b''):
            return Packet(command, tid, seq, payload).encode()
        if cmd == 1:
            return [reply(0x81, b'UIMG\x01\xff\x00\x04')]
        if cmd == 5:
            return [reply(0xff, b'\x01')] if self.old else [reply(0x85, b'EWIN\x01'+bytes([self.capacity])+b'\x00\x04')]
        if cmd == 2:
            self.next_seq = 1
            self.offset = 0
            self.cache.clear()
            self.mode = request.payload[5]
            return [reply(0x82)]
        if cmd == 4:
            if self.offset != len(self.raw) or seq != self.next_seq:
                return [reply(0xff, b'\x05')]
            return [reply(0x84)]
        self.counts[seq] += 1
        if seq == 9 and self.first_count_at_nine is None:
            self.first_count_at_nine = self.counts[1]
        if self.fatal:
            return [reply(0xff, bytes([self.fatal]))]
        if seq == self.drop_request and self.counts[seq] == 1:
            return []
        slot = seq % self.capacity
        cached = self.cache.get(slot)
        if cached and cached[0] == seq:
            return [cached[2]] if cached[1] == data else [reply(0xff, b'\x06')]
        if seq != self.next_seq:
            return [reply(0xff, b'\x04')]
        length = struct.unpack_from('<H', request.payload)[0]*2 if self.mode in (3,4,5,7) else len(request.payload)
        response = reply(0x83, self.output[self.offset:self.offset+length])
        self.offset += length
        self.next_seq = (self.next_seq + 1) & 0xffff
        self.executions[seq] += 1
        self.cache[slot] = (seq, data, response)
        if seq == self.drop_reply and self.counts[seq] == 1:
            return []
        if seq == self.corrupt and self.counts[seq] == 1:
            return [response[:-1]+bytes([response[-1]^1])]
        if self.reorder and seq == 1:
            self.held = response
            return []
        if self.reorder and seq == 8:
            return [response, self.held]
        return [response]


class EthernetWindowTests(unittest.TestCase):
    raw = bytes(range(256))*68

    def run_board(self, *, mode=0, window=8, attempts=3, **faults):
        board = WindowBoard(self.raw, 512, 17, mode, **faults)
        server = UdpResponder(board.handle)
        self.addCleanup(server.close)
        client = UdpImageClient(*server.peer, timeout=0.03, attempts=attempts, window_size=window)
        self.addCleanup(client.close)
        progress = []
        result = client.transfer(self.raw, 512, 17, mode, progress=lambda n,total: progress.append((n,total)))
        self.assertEqual(result, board.output)
        self.assertEqual(board.offset, len(self.raw))
        self.assertTrue(all(count == 1 for count in board.executions.values()))
        self.assertEqual(progress[-1], (len(self.raw), len(self.raw)))
        self.assertEqual([n for n,_ in progress], sorted(n for n,_ in progress))
        return client, board

    def test_eight_requests_can_be_outstanding_and_replies_reordered(self):
        client, _ = self.run_board(reorder=True)
        self.assertEqual(client.window_peak, 8)
        self.assertEqual(client.retry_count, 0)

    def test_missing_early_reply_cannot_evict_its_cache_slot(self):
        client, board = self.run_board(drop_reply=1)
        self.assertGreaterEqual(board.counts[1], 2)
        self.assertGreaterEqual(board.first_count_at_nine, 2)
        self.assertGreater(client.retry_count, 0)

    def test_missing_request_recovers_from_later_sequence_errors(self):
        client, board = self.run_board(drop_request=2)
        self.assertGreaterEqual(board.counts[2], 2)
        self.assertGreater(client.retry_count, 0)

    def test_corrupt_reply_is_retried_without_reexecuting(self):
        client, board = self.run_board(corrupt=3)
        self.assertGreaterEqual(board.counts[3], 2)
        self.assertEqual(client.bad_datagrams, 1)

    def test_filter_output_lengths_differ_from_uploads(self):
        client, _ = self.run_board(mode=3, drop_reply=1)
        self.assertEqual(client.active_window, 8)

    def test_old_firmware_explicitly_falls_back_to_one(self):
        client, _ = self.run_board(old=True)
        self.assertEqual(client.active_window, 1)
        self.assertEqual(client.window_peak, 1)

    def test_sixty_four_window_wrap_and_oldest_reply_retry(self):
        raw = bytes(range(256))*520
        board = WindowBoard(raw, 512, 130, capacity=64, drop_reply=1)
        server = UdpResponder(board.handle)
        self.addCleanup(server.close)
        client = UdpImageClient(*server.peer, timeout=0.1, window_size=64)
        self.addCleanup(client.close)
        self.assertEqual(client.transfer(raw,512,130,0),raw)
        self.assertEqual(client.window_peak,64)
        self.assertGreaterEqual(board.counts[1],2)
        self.assertEqual(len(board.executions),130)
        self.assertTrue(all(n == 1 for n in board.executions.values()))

    def test_new_client_negotiates_old_eight_slot_board(self):
        client, _ = self.run_board(window=64)
        self.assertEqual(client.active_window,8)

    def test_window_one_never_queries_optional_capability(self):
        client, _ = self.run_board(window=1)
        self.assertEqual(client.window_peak, 1)

    def test_conflicting_retry_error_is_fatal(self):
        with self.assertRaisesRegex(ProtocolError, 'conflicting retry'):
            self.run_board(fatal=6)

    def test_unrecoverable_gap_has_bounded_attempts(self):
        with self.assertRaises(TimeoutError):
            self.run_board(fatal=4, attempts=2)

    def test_invalid_window_rejected(self):
        for window in (0,65):
            with self.assertRaises(ValueError):
                UdpImageClient('127.0.0.1', window_size=window)


if __name__ == '__main__':
    unittest.main()
