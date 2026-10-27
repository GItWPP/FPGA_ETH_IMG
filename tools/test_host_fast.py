"""Fast-path framing, byte ownership, socket mode restoration and color parity."""
import socket
import struct
import threading
import time
import unittest
from unittest.mock import Mock,patch

import numpy as np
from PIL import Image

from eth_image import UdpImageClient,TransferCancelled
from rgb565_codec import encode_rgb565,decode_rgb565
from test_eth_transport import UdpResponder
from uart_image import Packet,Decoder,ProtocolError,crc16,image_to_rgb565,rgb565_to_image


class HostFastTests(unittest.TestCase):
    def make_client(self, handle, **kwargs):
        server = UdpResponder(handle)
        self.addCleanup(server.close)
        client = UdpImageClient(*server.peer,**kwargs)
        self.addCleanup(client.close)
        return client,server

    def test_complete_datagram_headers_crc_and_magic_in_payload(self):
        client,_ = self.make_client(lambda *_:[])
        for size in (0,1,17,1024):
            payload = (bytes.fromhex('55aa5aa5')*256)[:size]
            packet = Packet(0x83,65535,65534,payload)
            encoded = packet.encode()
            self.assertEqual(client._decode_datagram(encoded,client.peer),packet)
            for bad in (encoded[:13],b'x'+encoded,encoded+b'x',encoded+encoded,
                        encoded[:4]+b'\x02'+encoded[5:],encoded[:-1]+bytes([encoded[-1]^1])):
                self.assertIsNone(client._decode_datagram(bad,client.peer))
        too_long = bytes.fromhex('55aa5aa5')+struct.pack('<BBHHH',1,0x83,1,1,1025)+bytes(1027)
        self.assertIsNone(client._decode_datagram(too_long,client.peer))

    def test_receive_validates_once_without_reencoding(self):
        client,_ = self.make_client(lambda *_:[])
        encoded = Packet(0x83,3,4,bytes(range(256))*4).encode()
        with patch('eth_image.crc16',wraps=crc16) as checksum, \
             patch.object(Packet,'encode',side_effect=AssertionError('receive must not encode')):
            result = client._decode_datagram(encoded,client.peer)
            self.assertEqual(result.payload,bytes(range(256))*4)
            self.assertEqual(checksum.call_count,1)

    def test_codec_matches_scalar_for_modes_and_odd_shapes(self):
        rng = np.random.default_rng(529)
        source = Image.fromarray(rng.integers(0,256,(23,37,4),dtype=np.uint8),'RGBA')
        for image in (source,source.convert('RGB'),source.convert('L'),source.convert('P')):
            raw = encode_rgb565(image)
            self.assertEqual(raw,image_to_rgb565(image))
            self.assertEqual(decode_rgb565(raw,*image.size).tobytes(),
                             rgb565_to_image(raw,*image.size).tobytes())
        for raw,w,h in ((b'',0,1),(b'',1,0),(b'',-1,-1),(b'\x00',1,1),(b'\x00\x00',2,1)):
            with self.assertRaises(ValueError):
                decode_rgb565(raw,w,h)

    def test_window_reorder_owned_bytes_and_timeout_restoration(self):
        held = []
        modes = []
        def handle(data,count):
            packet = Decoder().feed(data)[0]
            if packet.cmd == 1:
                return [Packet(0x81,packet.transfer_id,packet.seq).encode()]
            modes.append(client.socket.gettimeout())
            response = Packet(0x83,packet.transfer_id,packet.seq,packet.payload).encode()
            if packet.seq == 1:
                held.append(response)
                return []
            return [response,*held] if packet.seq == 8 else [response]
        client,_ = self.make_client(handle,timeout=0.2)
        client.active_window = 8
        client.socket.settimeout(0.123)
        pieces = [bytes([n])*1024 for n in range(1,18)]
        result,next_seq = client._transfer_window(((x,len(x)) for x in pieces),7,17*1024,None)
        self.assertEqual(result,b''.join(pieces))
        self.assertEqual(next_seq,18)
        self.assertEqual(client.socket.gettimeout(),0.123)
        self.assertTrue(modes and all(x == 0 for x in modes))
        self.assertEqual(client.transact(Packet(1),0).cmd,0x81)

    def test_error_restores_socket_timeout(self):
        def handle(data,count):
            p = Decoder().feed(data)[0]
            return [Packet(0xff,p.transfer_id,p.seq,b'\x06').encode()]
        client,_ = self.make_client(handle)
        client.socket.settimeout(0.071)
        with self.assertRaisesRegex(ProtocolError,'conflicting retry'):
            client._transfer_window([(b'ab',2)],9,2,None)
        self.assertEqual(client.socket.gettimeout(),0.071)

    def test_timeout_restores_mode_and_limits_retries(self):
        client,server = self.make_client(lambda *_:[],timeout=0.02,attempts=2)
        client.socket.settimeout(0.071)
        with self.assertRaises(TimeoutError):
            client._transfer_window([(b'ab',2)],9,2,None)
        self.assertEqual(client.socket.gettimeout(),0.071)
        self.assertEqual(client.retry_count,1)
        self.assertEqual(len(server.requests),2)

    def test_cancel_restores_socket_timeout(self):
        cancel = threading.Event()
        client,_ = self.make_client(lambda *_:[],timeout=5,cancel_event=cancel)
        client.socket.settimeout(0.071)
        timer = threading.Timer(0.03,cancel.set)
        timer.start()
        start = time.monotonic()
        try:
            with self.assertRaises(TransferCancelled):
                client._transfer_window([(b'ab',2)],9,2,None)
        finally:
            timer.join()
        self.assertLess(time.monotonic()-start,0.3)
        self.assertEqual(client.socket.gettimeout(),0.071)
        self.assertEqual(client.retry_count,0)

    def test_send_buffer_backpressure_waits_then_sends_one_datagram(self):
        client,_ = self.make_client(lambda *_:[])
        original = client.socket
        fake = Mock()
        fake.send.side_effect = [BlockingIOError(),4]
        client.socket = fake
        try:
            with patch('eth_image.select.select',return_value=([],[fake],[])) as wait:
                client._send_datagram(b'abcd')
            self.assertEqual(wait.call_count,1)
            self.assertEqual(client.sent_datagrams,1)
            self.assertEqual(fake.send.call_args_list[0],fake.send.call_args_list[1])
        finally:
            client.socket = original

    def test_send_buffer_timeout_is_bounded(self):
        client,_ = self.make_client(lambda *_:[],timeout=1)
        original = client.socket
        client.socket = Mock()
        client.socket.send.side_effect = BlockingIOError()
        try:
            with patch('eth_image.time.monotonic',side_effect=[10,12]):
                with self.assertRaises(TimeoutError):
                    client._send_datagram(b'ab')
            self.assertEqual(client.sent_datagrams,0)
        finally:
            client.socket = original


if __name__ == '__main__':
    unittest.main()
