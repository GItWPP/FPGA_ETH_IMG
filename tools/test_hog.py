"""Independent geometry, integer feature, client and model regression tests."""
import struct
import unittest
from PIL import Image
from hog_client import HOGClient,prepare_hog,map_boxes,draw_detections
from hog_model import MODEL_ID,WEIGHTS,BIAS
from hog_reference import gradient_bin,extract_window,detect_reference,nms
from uart_image import Packet,ProtocolError


class FakeClient:
    def __init__(self): self.calls=[]
    def transact(self,packet,expected_length,**kwargs):
        self.calls.append((packet,expected_length,kwargs))
        if packet.cmd==0x1f:
            payload=struct.pack('<4sHHBBBBI',b'HOG1',320,240,64,128,8,1,MODEL_ID)
        elif packet.cmd==0x12: payload=struct.pack('<H',495)
        elif packet.cmd==0x13:
            offset,count=struct.unpack('<HH',packet.payload)
            payload=struct.pack(f'<{count}i',*(i-300 for i in range(offset,offset+count)))
        else: payload=b''
        assert len(payload)==expected_length
        return Packet(packet.cmd|0x80,packet.transfer_id,packet.seq,payload)


class HOGTests(unittest.TestCase):
    def test_gradient_axes_signs_and_bins(self):
        self.assertEqual(gradient_bin(255,0),(0,255))
        self.assertEqual(gradient_bin(-255,0),(0,255))
        self.assertEqual(gradient_bin(0,-255),(4,255))
        self.assertEqual(gradient_bin(255,255),(2,510))
        self.assertEqual(gradient_bin(-255,255),(6,510))
        self.assertEqual(gradient_bin(0,0),(0,0))

    def test_descriptor_zero_and_model_shape(self):
        self.assertEqual(extract_window(bytes([55])*8192),[0]*3780)
        self.assertEqual(len(WEIGHTS),3780)
        self.assertTrue(all(-32768<=w<=32767 for w in WEIGHTS))
        self.assertEqual(detect_reference(bytes([55])*76800),[BIAS]*495)

    def test_letterbox_aspect_and_tiny_images(self):
        for size in [(1920,1080),(1,1080),(1920,1),(1,1),(321,213),(320,240)]:
            gray,g=prepare_hog(Image.new('RGB',size,'white'))
            self.assertEqual(len(gray),76800)
            self.assertTrue(1<=g[2]<=320 and 1<=g[3]<=240)
            self.assertEqual((g[4],g[5]),size)

    def test_box_mapping_and_nms(self):
        scores=[-1]*495
        scores[7*33+16]=100
        scores[7*33+17]=50
        boxes=map_boxes(scores,(0,0,320,240,640,480),threshold=0)
        self.assertEqual(boxes,[(256,112,384,368,100)])
        self.assertEqual(len(nms(scores)),1)
        original=Image.new('RGB',(640,480))
        output,boxes2=draw_detections(original,scores,(0,0,320,240,640,480),threshold=0)
        self.assertEqual(output.size,original.size)
        self.assertEqual(boxes,boxes2)
        self.assertNotEqual(output.tobytes(),original.tobytes())

    def test_client_lengths_sequence_and_signed_scores(self):
        fake=FakeClient()
        result=HOGClient(fake).detect(bytes(76800),transfer_id=1234)
        self.assertEqual(result,list(range(-300,195)))
        packets=[c[0] for c in fake.calls]
        self.assertEqual([p.seq for p in packets[1:]],list(range(79)))
        self.assertEqual([len(p.payload) for p in packets if p.cmd==0x11],[1024]*75)
        self.assertEqual(next(c[2]['timeout'] for c in fake.calls if c[0].cmd==0x12),5)

    def test_client_rejects_bad_frame_before_serial(self):
        fake=FakeClient()
        with self.assertRaises(ValueError): HOGClient(fake).detect(bytes(76799))
        self.assertEqual(fake.calls,[])


if __name__=='__main__': unittest.main()
