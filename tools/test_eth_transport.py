import socket
import threading
import unittest

from eth_image import UdpImageClient, network_endpoint
from uart_image import Decoder, Packet, ProtocolError


class UdpResponder:
    def __init__(self, handle):
        self.handle = handle
        self.requests = []
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(('127.0.0.1', 0))
        self.peer = self.socket.getsockname()
        self.socket.settimeout(0.02)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stop.is_set():
            try:
                data, address = self.socket.recvfrom(65535)
            except socket.timeout:
                continue
            self.requests.append(data)
            for reply in self.handle(data, len(self.requests)):
                self.socket.sendto(reply, address)

    def close(self):
        self.stop.set()
        self.thread.join(timeout=1)
        self.socket.close()


class EthernetTransportTests(unittest.TestCase):
    def make_client(self, handle, **options):
        responder = UdpResponder(handle)
        self.addCleanup(responder.close)
        client = UdpImageClient(*responder.peer, timeout=0.03, **options)
        self.addCleanup(client.close)
        return client, responder

    def test_exact_datagram_retry_and_maximum_payload(self):
        request = Packet(3, 42, 7, bytes(range(256))*4)
        response = Packet(0x83, 42, 7, request.payload).encode()
        client, server = self.make_client(lambda data, count: [] if count == 1 else [response])
        self.assertEqual(client.transact(request, 1024).payload, request.payload)
        self.assertEqual(client.retry_count, 1)
        self.assertEqual(server.requests, [request.encode(), request.encode()])
        self.assertEqual(len(server.requests[0]), 1038)

    def test_datagrams_never_join_and_concatenation_rejected(self):
        good = Packet(0x81, 11, 2, b'ok').encode()
        client, _ = self.make_client(lambda data, count: [good[:8], good[8:], good+good, b'x'+good, good])
        self.assertEqual(client.transact(Packet(1, 11, 2), 2).payload, b'ok')
        self.assertEqual(client.bad_datagrams, 4)

    def test_bad_crc_and_old_sequence_are_ignored(self):
        good = Packet(0x83, 9, 4, b'ab').encode()
        bad = good[:-1] + bytes([good[-1]^1])
        stale = Packet(0x83, 9, 3, b'ab').encode()
        client, _ = self.make_client(lambda data, count: [bad, stale, good])
        self.assertEqual(client.transact(Packet(3, 9, 4), 2).payload, b'ab')
        self.assertEqual(client.bad_datagrams, 1)

    def test_fpga_error_is_not_retried(self):
        client, server = self.make_client(lambda data, count: [Packet(0xff, 9, 4, b'\x04').encode()])
        with self.assertRaisesRegex(ProtocolError, 'unexpected sequence'):
            client.transact(Packet(3, 9, 4), 2)
        self.assertEqual(len(server.requests), 1)

    def test_timeout_has_bounded_retries(self):
        client, server = self.make_client(lambda data, count: [], attempts=2)
        with self.assertRaises(TimeoutError):
            client.transact(Packet(1), 8)
        self.assertEqual(client.retry_count, 1)
        self.assertEqual(len(server.requests), 2)

    def test_connected_socket_rejects_other_source_port(self):
        good = Packet(0x81, 0, 0, b'UIMG\x01\xff\x00\x04').encode()
        def reply(data, count):
            attacker = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                attacker.sendto(Packet(0xff, 0, 0, b'\x04').encode(), client.socket.getsockname())
            finally:
                attacker.close()
            return [good]
        client, _ = self.make_client(reply)
        self.assertEqual(client.ping(), b'UIMG\x01\xff\x00\x04')

    def test_endpoint_and_lengths_rejected_before_network_send(self):
        for host, port in [('COM11', 1234), ('192.168.1.12', 0), ('224.1.1.1', 1234)]:
            with self.assertRaises(ValueError):
                network_endpoint(host, port)
        client, server = self.make_client(lambda data, count: [])
        with self.assertRaises(ValueError):
            client.transact(Packet(3, payload=bytes(1025)), 0)
        with self.assertRaises(ValueError):
            client.transact(Packet(3), 1025)
        self.assertEqual(server.requests, [])
