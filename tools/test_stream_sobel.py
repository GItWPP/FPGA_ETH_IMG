"""Independent stream protocol, border packing and loss/retry tests."""
from collections import Counter
import struct
import unittest
import numpy as np
from PIL import Image
from eth_image import UdpImageClient
from stream_sobel import pad_rgb565,iter_stream_chunks,decode_gray8,prepare_sobel_frame
from test_eth_transport import UdpResponder
from uart_image import Decoder,Packet,ProtocolError


def independent_reference(raw,width,height):
    # Scalar arithmetic independent from the FPGA and production packing helpers.
    values=struct.unpack(f'<{width*height}H',raw)
    gray=[]
    for pixel in values:
        r,g,b=pixel>>11,(pixel>>5)&63,pixel&31
        gray.append((77*((r<<3)|(r>>2))+150*((g<<2)|(g>>4))+29*((b<<3)|(b>>2)))>>8)
    out=bytearray()
    for y in range(height):
        for x in range(width):
            n=[gray[min(height-1,max(0,y+dy))*width+min(width-1,max(0,x+dx))]
                for dy in (-1,0,1) for dx in (-1,0,1)]
            gx=n[2]+2*n[5]+n[8]-n[0]-2*n[3]-n[6]
            gy=n[6]+2*n[7]+n[8]-n[0]-2*n[1]-n[2]
            out.append(min(255,abs(gx)+abs(gy)))
    return bytes(out)


class StreamBoard:
    def __init__(self,raw,width,height,*,drop_request=0,drop_reply=0,reorder=False,corrupt=0):
        self.raw,self.width,self.height=raw,width,height
        self.result=independent_reference(raw,width,height)
        rows=[raw[y*width*2:(y+1)*width*2] for y in range(height)]
        self.padded=b''.join(row+row[-2:] for row in rows+[rows[-1]])
        self.drop_request,self.drop_reply,self.reorder=drop_request,drop_reply,reorder
        self.corrupt=corrupt
        self.calls=Counter();self.executions=Counter();self.cache={}
        self.pos=0;self.output_pos=0;self.next_seq=1;self.held=None

    def handle(self,data,count):
        p=Decoder().feed(data)[0]
        def reply(cmd,payload=b''):return Packet(cmd,p.transfer_id,p.seq,payload).encode()
        if p.cmd==5:return [reply(0x85,b'EWIN\x01\x40\x00\x04')]
        if p.cmd==0x40:
            self.pos=self.output_pos=0;self.next_seq=1;self.cache.clear()
            return [reply(0xc0,b'SBL1'+struct.pack('<HH',self.width,self.height))]
        if p.cmd==0x42:
            assert self.pos==len(self.padded) and self.output_pos==len(self.result)
            return [reply(0xc2,struct.pack('<I',len(self.result)))]
        assert p.cmd==0x41
        self.calls[p.seq]+=1
        if p.seq==self.drop_request and self.calls[p.seq]==1:return []
        if p.seq in self.cache:return [self.cache[p.seq]]
        if p.seq!=self.next_seq:return [reply(255,b'\x04')]
        assert p.payload==self.padded[self.pos:self.pos+len(p.payload)]
        first,last=self.pos//2,(self.pos+len(p.payload))//2
        valid=sum(1 for k in range(first,last) if k//(self.width+1)>0 and k%(self.width+1)>0)
        encoded=reply(0xc1,self.result[self.output_pos:self.output_pos+valid])
        self.output_pos+=valid;self.pos+=len(p.payload);self.next_seq+=1
        self.executions[p.seq]+=1;self.cache[p.seq]=encoded
        if p.seq==self.drop_reply and self.calls[p.seq]==1:return []
        if p.seq==self.corrupt and self.calls[p.seq]==1:return [encoded[:-1]+bytes([encoded[-1]^1])]
        if self.reorder and p.seq==1:self.held=encoded;return []
        if self.reorder and p.seq==8:return [encoded,self.held]
        return [encoded]


class StreamSobelTests(unittest.TestCase):
    def board_case(self,width,height,*,native=True,window=8,**options):
        raw=struct.pack(f'<{width*height}H',*((i*71+i//width*139)&65535 for i in range(width*height)))
        board=StreamBoard(raw,width,height,**options)
        server=UdpResponder(board.handle);self.addCleanup(server.close)
        client=UdpImageClient(*server.peer,timeout=0.08,window_size=window);self.addCleanup(client.close)
        client.native_stream=native
        progress=[]
        self.assertEqual(client.transfer_sobel_stream(raw,width,height,progress=lambda n,t:progress.append((n,t))),board.result)
        self.assertEqual(progress[-1],(width*height,width*height))
        self.assertTrue(all(n==1 for n in board.executions.values()))
        return client,board

    def test_single_pixel_and_thin_images(self):
        for w,h in [(1,1),(1,11),(13,1),(7,9)]:
            with self.subTest(size=(w,h)):self.board_case(w,h)

    def test_zero_output_packets_and_maximum_width(self):self.board_case(1920,3)
    def test_odd_width_and_cache_wrap(self):self.board_case(257,140)
    def test_lost_request(self):
        client,_=self.board_case(79,31,drop_request=2)
        self.assertGreater(client.retry_count,0)
    def test_lost_reply(self):
        client,board=self.board_case(79,31,drop_reply=1)
        self.assertGreater(board.calls[1],1)
        self.assertGreater(client.retry_count,0)
    def test_reordered_zero_length_reply(self):self.board_case(1920,3,reorder=True)
    def test_native_sixty_four_window_loss_and_wrap(self):
        client,board=self.board_case(257,260,window=64,drop_reply=1)
        self.assertEqual(client.window_peak,64)
        self.assertGreater(board.calls[1],1)
        self.assertGreater(client.retry_count,0)

    def test_python_fallback_keeps_identical_loss_recovery(self):
        client,_=self.board_case(79,31,native=False,drop_reply=1)
        self.assertEqual(client.stream_backend,'python')
        self.assertGreater(client.retry_count,0)

    def test_native_corrupt_crc_retries_without_reexecution(self):
        client,_=self.board_case(79,31,corrupt=3)
        self.assertEqual(client.bad_datagrams,1)
        self.assertGreater(client.retry_count,0)

    def test_cancel_stalled_native_window_is_bounded(self):
        import threading,time
        from eth_image import TransferCancelled
        raw=bytes(79*31*2);board=StreamBoard(raw,79,31)
        def handle(data,count):
            p=Decoder().feed(data)[0]
            return [] if p.cmd==0x41 else board.handle(data,count)
        server=UdpResponder(handle);self.addCleanup(server.close)
        cancel=threading.Event()
        client=UdpImageClient(*server.peer,timeout=0.5,cancel_event=cancel);self.addCleanup(client.close)
        timer=threading.Timer(0.05,cancel.set);timer.start();self.addCleanup(timer.cancel)
        started=time.monotonic()
        with self.assertRaises(TransferCancelled):client.transfer_sobel_stream(raw,79,31)
        self.assertLess(time.monotonic()-started,0.3)
        self.assertNotEqual(client.socket.gettimeout(),0.0)

    def test_prepared_border_and_gray_display(self):
        image=Image.fromarray(np.arange(11*7*3,dtype=np.uint8).reshape(7,11,3))
        prepared=prepare_sobel_frame(image)
        chunks=list(iter_stream_chunks(prepared.padded,11,7))
        self.assertEqual(sum(n for _,n in chunks),77)
        out=decode_gray8(bytes(range(77)),11,7)
        self.assertEqual(out.getpixel((10,6)),(76,76,76))
    def test_invalid_lengths(self):
        with UdpImageClient('127.0.0.1') as client:
            for args in [(b'',1,1),(b'12',1921,1),(b'12',1,1081)]:
                with self.assertRaises(ValueError):client.transfer_sobel_stream(*args)
        with self.assertRaises(ValueError):pad_rgb565(b'',1,1)
        with self.assertRaises(ValueError):list(iter_stream_chunks(b'12',1,1))
        with self.assertRaises(ValueError):decode_gray8(b'',1,1)

class StreamVideoWorkerTests(unittest.TestCase):
    def make_session(self,*,failure=False):
        import time
        from types import SimpleNamespace
        from video_pipeline import VideoSession
        observed=[];clients=[]
        class Reader:
            def __init__(self,*args,**kwargs):
                self.info=SimpleNamespace(width=13,height=9,fps=25.0,frame_count=8)
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read_at(self,index):
                if index>=8:return None
                image=Image.new('RGB',(13,9),(index*17,33,94))
                return image
        class Client:
            def __init__(self,*args,**kwargs):
                self.retry_count=0;self.closed=False;self.window=kwargs['window_size'];clients.append(self)
            def __enter__(self):return self
            def __exit__(self,*args):self.closed=True
            def transfer_sobel_stream(self,raw,w,h,*,padded=False):
                assert padded and (w,h)==(13,9)
                if failure:raise RuntimeError('injected stream network failure')
                observed.append(raw)
                original=b''.join(raw[y*(w+1)*2:y*(w+1)*2+w*2] for y in range(h))
                return independent_reference(original,w,h)
        return VideoSession('fake.mp4',mode=5,bounds=None,realtime=False,
            reader_factory=Reader,client_factory=Client),observed,clients

    def test_prefetch_sequential_frames_use_64_window_and_close(self):
        session,observed,clients=self.make_session();session.start()
        self.assertTrue(session.done.wait(2))
        self.assertIsNone(session.error)
        self.assertEqual(session.snapshot()['processed'],8)
        self.assertEqual(session.snapshot()['skipped'],0)
        self.assertEqual(len(observed),8)
        self.assertEqual(clients[0].window,64)
        self.assertTrue(clients[0].closed)
        self.assertEqual(session.take_latest().index,7)

    def test_prefetch_pause_and_stop_close_both_workers(self):
        import time
        session,_,clients=self.make_session();session.start()
        deadline=time.monotonic()+1
        while session.snapshot()['processed']<2 and time.monotonic()<deadline:time.sleep(0.001)
        session.pause();time.sleep(0.04)
        before=session.snapshot()['processed'];time.sleep(0.08)
        self.assertEqual(session.snapshot()['processed'],before)
        session.resume();time.sleep(0.02);session.stop()
        self.assertTrue(session.done.wait(0.5))
        self.assertEqual(session.snapshot()['state'],'stopped')
        self.assertTrue(clients[0].closed)

    def test_prefetch_network_failure_terminates_full_queue(self):
        session,_,clients=self.make_session(failure=True);session.start()
        self.assertTrue(session.done.wait(1))
        self.assertEqual(session.snapshot()['state'],'failed')
        self.assertIn('injected stream network failure',session.error)
        self.assertTrue(clients[0].closed)

    def test_vector_reference_matches_scalar(self):
        from stream_sobel_reference import reference_gray8
        raw=struct.pack('<493H',*((i*71)&65535 for i in range(493)))
        self.assertEqual(reference_gray8(raw,17,29),independent_reference(raw,17,29))


if __name__=='__main__':unittest.main()
