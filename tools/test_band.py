import struct
import tempfile
import unittest
from pathlib import Path
import numpy as np
from PIL import Image
from uart_image import Packet, ProtocolError
from band_client import BandClient, BandResult, prepare_band, draw_band, export_band
from band_reference import decode_integer
from generate_band_vectors import synthetic
from project_paths import user_test_image, user_test_images


class ReplyClient:
    def __init__(self, result, width, height):
        self.result, self.width, self.height = result, width, height
        self.requests = []
        self.bad_info = False

    def transact(self, packet, size, **kwargs):
        self.requests.append(packet)
        r = self.result
        if packet.cmd == 0x2f:
            data = struct.pack('<4sHHBBHI', b'BAD!' if self.bad_info else b'BND1', 512, 512, 1, 2, 4096, 0)
        elif packet.cmd in (0x20, 0x21):
            data = b''
        elif packet.cmd == 0x22:
            data = struct.pack('<4sHBBHHHH', b'BND1', len(r['cells']), r['rows'], r['status'], r['pitch_q8'], self.width, self.height, r['dots'])
        else:
            offset, count = struct.unpack('<HH', packet.payload)
            data = struct.pack(f'<{count}I', *r['cells'][offset:offset+count])
        assert len(data) == size
        return Packet(packet.cmd | 0x80, packet.transfer_id, packet.seq, data)


class BandTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gray, cls.truth = synthetic()
        cls.result = decode_integer(cls.gray)

    def test_native_gray_and_dimension_limit(self):
        image = Image.new('L', (33, 32), 123)
        self.assertEqual(prepare_band(image), bytes([123])*1056)
        for size in [(513, 32), (32, 513), (15, 32)]:
            with self.assertRaises(ValueError):
                prepare_band(Image.new('L', size))

    def test_known_bits_under_noise_and_row_drift(self):
        self.assertEqual(self.result['status'], 0)
        self.assertEqual(self.result['rows'], 8)
        self.assertAlmostEqual(self.result['pitch_q8']/256, 17, delta=0.1)
        b = BandResult(256, 160, 8, self.result['pitch_q8'], self.result['dots'], self.result['cells'])
        for cell in b.cells:
            candidates = [p for p in self.truth if p[0] == cell['row']]
            point = min(candidates, key=lambda p: abs(p[1]-cell['x']))
            if abs(point[1]-cell['x']) <= 3:
                self.assertEqual(cell['bit'], point[3])
            else:
                self.assertTrue(cell['partial'])
                self.assertEqual(cell['bit'], 0)

    def test_uniform_frame_reports_no_band(self):
        result = decode_integer(np.full((33, 47), 127, dtype='uint8'))
        self.assertEqual((result['status'], result['cells']), (1, []))

    def test_oversized_point_list_rejected(self):
        gray = np.full((512, 512), 170, dtype='uint8')
        gray[4::8, 4::8] = 20
        self.assertEqual(decode_integer(gray)['status'], 3)

    def test_client_exact_words_and_native_payload(self):
        mock = ReplyClient(self.result, 256, 160)
        result = BandClient(mock).decode(self.gray.tobytes(), 256, 160, transfer_id=10)
        self.assertEqual(result.words, self.result['cells'])
        self.assertEqual(b''.join(p.payload for p in mock.requests if p.cmd == 0x21), self.gray.tobytes())
        self.assertEqual([p.seq for p in mock.requests[1:]], list(range(len(mock.requests)-1)))

    def test_wrong_info_fails_before_upload(self):
        mock = ReplyClient(self.result, 256, 160)
        mock.bad_info = True
        with self.assertRaises(ProtocolError):
            BandClient(mock).decode(self.gray.tobytes(), 256, 160)
        self.assertEqual(len(mock.requests), 1)

    def test_status_error_has_no_result_reads(self):
        mock = ReplyClient(dict(status=2, cells=[], rows=4, pitch_q8=4096, dots=40), 16, 16)
        with self.assertRaisesRegex(ProtocolError, '同步'):
            BandClient(mock).decode(bytes(256), 16, 16)
        self.assertFalse(any(p.cmd == 0x23 for p in mock.requests))

    def test_bad_result_flags_rejected(self):
        data = {**self.result, 'cells': self.result['cells'].copy()}
        data['cells'][0] |= 1 << 19
        with self.assertRaisesRegex(ProtocolError, '标志'):
            BandClient(ReplyClient(data, 256, 160)).decode(self.gray.tobytes(), 256, 160)

    def test_export_preserves_rows_and_excludes_sync(self):
        b = BandResult(256, 160, 8, self.result['pitch_q8'], self.result['dots'], self.result['cells'])
        with tempfile.TemporaryDirectory() as directory:
            image_path = Path(directory)/'result.png'
            bits = export_band(draw_band(Image.fromarray(self.gray), b), b, image_path)
            self.assertEqual(bits.read_text().splitlines(), b.binary_rows())
            self.assertEqual(len(bits.read_text().splitlines()), 6)
            self.assertEqual(len((Path(directory)/'result_sync.txt').read_text().splitlines()), 2)
            with Image.open(image_path) as saved:
                self.assertEqual(saved.size, (256, 160))

    def test_repository_band_samples_and_verified_regression(self):
        root = Path(__file__).resolve().parents[1]
        with Image.open(user_test_image('1.png')) as image:
            gray = np.asarray(image.convert('L'))
        r = decode_integer(gray)
        b = BandResult(512, 512, r['rows'], r['pitch_q8'], r['dots'], r['cells'])
        self.assertEqual((r['status'], b.rows, sum(map(len, b.binary_rows()))), (0, 21, 575))
        expected=(root/'test_img/expected/band_1_bits.txt').read_text().splitlines()
        self.assertEqual(b.binary_rows(),expected)
        for path in user_test_images('band'):
            with self.subTest(image=path.name), Image.open(path) as image:
                result=decode_integer(np.asarray(image.convert('L')))
                self.assertEqual((result['status'],result['rows']),(0,21))
                sync=[word for word in result['cells'] if (word>>19)&1]
                self.assertGreaterEqual(sum((word>>18)&1 for word in sync)/len(sync),0.9)

    def test_gui_binary_view_export_and_mode_switch(self):
        import tkinter as tk
        from unittest.mock import patch
        from eth_image_gui import ImageApp
        from band_client import BAND_LABEL
        root = tk.Tk()
        root.withdraw()
        app = ImageApp(root)
        try:
            with tempfile.TemporaryDirectory() as directory:
                source_path = Path(directory)/'source.png'
                Image.fromarray(self.gray).save(source_path)
                app.mode.set(BAND_LABEL)
                app.load_image(source_path)
                self.assertIn('512', app.size_hint.cget('text'))
                self.assertEqual(app.left_image.image.size, (256, 160))
                self.assertEqual(app.hog_threshold_entry.winfo_manager(), '')
                app.band_result = BandResult(256, 160, 8, self.result['pitch_q8'], self.result['dots'], self.result['cells'])
                app.result = draw_band(app.source, app.band_result)
                app.show_binary()
                app.binary_window.withdraw()
                root.update()
                self.assertTrue(app.binary_window.winfo_exists())
                output_path = Path(directory)/'export.png'
                with patch('eth_image_gui.filedialog.asksaveasfilename', return_value=str(output_path)):
                    app.save()
                self.assertEqual((Path(directory)/'export_bits.txt').read_text().splitlines(), app.band_result.binary_rows())
                app.mode.set('Gamma 暗部提亮')
                app.update_source_preview()
                self.assertIsNone(app.band_result)
                self.assertIsNone(app.binary_window)
                self.assertEqual(app.binary_button.winfo_manager(), '')
        finally:
            root.after_cancel(app._poll_job)
            root.destroy()


if __name__ == '__main__':
    unittest.main()
