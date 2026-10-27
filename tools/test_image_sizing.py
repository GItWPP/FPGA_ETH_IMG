import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image
from uart_image import load_source_image, prepare_image, image_to_rgb565


class NativeImageTests(unittest.TestCase):
    def test_native_dimensions_and_pixels_are_preserved(self):
        for size in ((1, 1), (17, 19), (321, 213), (479, 803), (1920, 1), (1, 1080), (1920, 1080)):
            with self.subTest(size=size):
                source = Image.new("RGB", size, (37, 103, 211))
                actual = prepare_image(source)
                self.assertEqual(actual.size, size)
                self.assertEqual(actual.tobytes(), source.tobytes())
                self.assertEqual(len(image_to_rgb565(actual)), size[0] * size[1] * 2)

    def test_png_size_is_read_from_file(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "任意尺寸 321x213.png"
            Image.new("RGB", (321, 213), (13, 29, 47)).save(path)
            actual = prepare_image(load_source_image(path))
            self.assertEqual(actual.size, (321, 213))
            self.assertEqual(actual.getpixel((320, 212)), (13, 29, 47))

    def test_jpeg_orientation_is_applied_before_size_detection(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "rotated.jpg"
            image = Image.new("RGB", (201, 101), (41, 73, 101))
            exif = image.getexif()
            exif[274] = 6
            image.save(path, exif=exif)
            self.assertEqual(load_source_image(path).size, (101, 201))

    def test_oversize_requires_explicit_manual_resize(self):
        for size in ((1921, 1080), (1920, 1081), (1080, 1920)):
            with self.subTest(size=size):
                source = Image.new("RGB", size)
                with self.assertRaises(ValueError):
                    prepare_image(source)
                self.assertEqual(prepare_image(source, 640, 480).size, (640, 480))

    def test_incomplete_manual_dimensions_are_rejected(self):
        for width, height in ((320, None), (None, 240), (0, 240)):
            with self.assertRaises(ValueError):
                prepare_image(Image.new("RGB", (321, 213)), width, height)


class GuiNativeSizeTests(unittest.TestCase):
    def setUp(self):
        import tkinter as tk
        import eth_image_gui
        self.root = tk.Tk()
        self.root.withdraw()
        self.app = eth_image_gui.ImageApp(self.root)
        self.temp = tempfile.TemporaryDirectory()

    def tearDown(self):
        for callback in self.root.tk.call("after", "info"):
            self.root.after_cancel(callback)
        self.root.destroy()
        self.temp.cleanup()

    def file(self, size):
        path = Path(self.temp.name) / f"native_{size[0]}x{size[1]}.png"
        Image.new("RGB", size, (53, 97, 181)).save(path)
        return path

    def test_default_auto_follows_consecutive_files_and_clears_stale_result(self):
        self.assertTrue(self.app.auto_size.get())
        for size in ((321, 213), (17, 19), (479, 803), (1920, 1080)):
            self.app.result = Image.new("RGB", (1, 1))
            self.app.load_image(self.file(size))
            self.assertEqual(self.app.dimensions(), size)
            self.assertEqual((self.app.width.get(), self.app.height.get()), tuple(map(str, size)))
            self.assertEqual(str(self.app.width_entry["state"]), "readonly")
            self.assertIsNone(self.app.result)
            self.assertEqual(str(self.app.save_button["state"]), "disabled")

    def test_manual_resize_and_return_to_automatic(self):
        self.app.load_image(self.file((321, 213)))
        self.app.size_preset.set("128×128")
        self.app.select_preset()
        self.assertFalse(self.app.auto_size.get())
        self.assertEqual(self.app.dimensions(), (128, 128))
        self.assertEqual(str(self.app.width_entry["state"]), "normal")
        self.app.use_original_size()
        self.assertTrue(self.app.auto_size.get())
        self.assertEqual(self.app.dimensions(), (321, 213))

    def test_oversize_is_not_silently_rescaled(self):
        self.app.load_image(self.file((1921, 100)))
        self.assertEqual(self.app.source.size, (1921, 100))
        with self.assertRaises(ValueError):
            self.app.dimensions()
        self.app.size_preset.set("640×480")
        self.app.select_preset()
        self.assertEqual(self.app.dimensions(), (640, 480))


if __name__ == "__main__":
    unittest.main(verbosity=2)
