"""Real Tk widget events verify viewing behavior without altering image data."""
import hashlib
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from PIL import Image
from uart_image import image_to_rgb565, rgb565_to_image


class ViewerTests(unittest.TestCase):
    def setUp(self):
        import tkinter as tk
        import eth_image_gui
        self.root = tk.Tk()
        self.root.attributes("-alpha", 0.0)
        self.app = eth_image_gui.ImageApp(self.root)
        self.root.update()
        self.viewer = self.app.left_image
        self.viewer.set_image(Image.new("RGB", (1920, 1080), (53, 97, 181)))
        self.root.update()

    def tearDown(self):
        for callback in self.root.tk.call("after", "info"):
            self.root.after_cancel(callback)
        self.root.destroy()

    def test_mouse_wheel_keeps_cursor_on_same_image_point(self):
        self.viewer.actual_size()
        self.root.update()
        before = self.viewer.image_point(200, 160)
        self.viewer.canvas.event_generate("<MouseWheel>", x=200, y=160, delta=120)
        self.root.update()
        after = self.viewer.image_point(200, 160)
        self.assertGreater(self.viewer.scale, 1)
        self.assertAlmostEqual(before[0], after[0])
        self.assertAlmostEqual(before[1], after[1])

    def test_left_drag_moves_image_and_release_stops_dragging(self):
        self.viewer.actual_size()
        self.root.update()
        ox, oy = self.viewer.offset_x, self.viewer.offset_y
        canvas = self.viewer.canvas
        canvas.event_generate("<ButtonPress-1>", x=200, y=160)
        canvas.event_generate("<B1-Motion>", x=245, y=185)
        canvas.event_generate("<ButtonRelease-1>", x=245, y=185)
        self.root.update()
        self.assertAlmostEqual(self.viewer.offset_x, ox + 45)
        self.assertAlmostEqual(self.viewer.offset_y, oy + 25)
        self.assertIsNone(self.viewer._drag)
        self.assertFalse(self.viewer.fit_mode)

    def test_extreme_zoom_renders_only_the_viewport(self):
        self.viewer.zoom(1e12)
        self.root.update()
        width, height = self.viewer.viewport_size()
        self.assertEqual(self.viewer.scale, self.viewer.MAX_SCALE)
        self.assertLessEqual(self.viewer.rendered_size[0], width + 2 * self.viewer.MAX_SCALE)
        self.assertLessEqual(self.viewer.rendered_size[1], height + 2 * self.viewer.MAX_SCALE)
        self.viewer.zoom(1e-12)
        self.root.update()
        self.assertEqual(self.viewer.scale, self.viewer.MIN_SCALE)

    def test_small_image_can_pan_without_changing_scale(self):
        self.viewer.set_image(Image.new("RGB", (100, 80)))
        self.root.update()
        ox, oy = self.viewer.offset_x, self.viewer.offset_y
        self.viewer.pan(20, 10)
        self.root.update()
        self.assertEqual(self.viewer.scale, 1)
        self.assertAlmostEqual(self.viewer.offset_x, ox + 20)
        self.assertAlmostEqual(self.viewer.offset_y, oy + 10)

    def test_fit_one_to_one_and_double_click(self):
        self.viewer.actual_button.invoke()
        self.root.update()
        self.assertEqual(self.viewer.scale, 1)
        self.assertTrue(self.viewer.canvas.bind("<Double-Button-1>"))
        self.viewer._on_double_click(SimpleNamespace())
        self.root.update()
        width, height = self.viewer.viewport_size()
        self.assertTrue(self.viewer.fit_mode)
        self.assertLessEqual(self.viewer.image.width * self.viewer.scale, width - 30)
        self.assertLessEqual(self.viewer.image.height * self.viewer.scale, height - 30)

    def test_resize_preserves_manual_scale_and_recomputes_fit(self):
        # Permit an actual shrink even when a CI desktop starts at the app minimum.
        self.root.minsize(640, 480)
        before_fit = self.viewer.scale
        self.root.geometry("960x640")
        self.root.update()
        self.assertLess(self.viewer.scale, before_fit)
        self.viewer.zoom(4)
        manual = self.viewer.scale
        self.root.geometry("1180x780")
        self.root.update()
        self.assertAlmostEqual(self.viewer.scale, manual)

    def test_viewing_does_not_change_source_or_send_dimensions(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "source.png"
            Image.new("RGB", (321, 213), (53, 97, 181)).save(path)
            self.app.load_image(path)
            self.root.update()
            digest = hashlib.sha256(self.app.source.tobytes()).digest()
            wanted = rgb565_to_image(image_to_rgb565(self.app.source), 321, 213)
            self.assertEqual(self.viewer.image.tobytes(), wanted.tobytes())
            self.viewer.zoom(8)
            self.viewer.pan(100, -100)
            self.viewer.actual_size()
            self.app.update_source_preview()
            self.root.update()
            self.assertEqual(self.viewer.scale, 1)
            self.assertEqual(self.app.dimensions(), (321, 213))
            self.assertEqual(hashlib.sha256(self.app.source.tobytes()).digest(), digest)

    def test_settings_collapse_and_minimum_window_controls_fit(self):
        self.assertTrue(self.app.settings_panel.winfo_ismapped())
        self.root.geometry("1100x720")
        self.root.update()
        self.assertTrue(self.app.settings_panel.winfo_ismapped())
        for widget in (self.app.save_button, self.app.height_entry, self.app.right_image):
            self.assertLessEqual(widget.winfo_rootx() + widget.winfo_width(),
                                 self.root.winfo_rootx() + self.root.winfo_width())
        self.assertGreater(self.viewer.canvas.winfo_height(), 100)
        self.app.toggle_settings()
        self.root.update()
        self.assertFalse(self.app.settings_panel.winfo_ismapped())
        self.app.toggle_settings()
        self.root.update()
        self.assertTrue(self.app.settings_panel.winfo_ismapped())

    def test_video_frame_update_preserves_zoom_and_pan(self):
        self.viewer.zoom(8)
        self.viewer.pan(31,-17)
        self.root.update()
        before = self.viewer.scale,self.viewer.offset_x,self.viewer.offset_y
        self.viewer.update_image(Image.new('RGB',(1920,1080),(20,30,40)))
        self.root.update()
        self.assertEqual((self.viewer.scale,self.viewer.offset_x,self.viewer.offset_y),before)
        self.assertEqual(self.viewer.image.getpixel((0,0)),(20,30,40))

    def test_video_fit_can_fill_the_viewport_and_return_to_actual_size(self):
        self.viewer.allow_upscale = True
        self.viewer.set_image(Image.new('RGB',(320,180)))
        self.root.update()
        self.assertGreater(self.viewer.scale,1)
        self.assertEqual(self.viewer.image.size,(320,180))
        self.viewer.actual_size()
        self.assertAlmostEqual(self.viewer.scale,1)

    def test_views_remain_interactive_while_transferring(self):
        self.app.set_busy(True)
        self.assertEqual(str(self.app.mode_combo["state"]), "disabled")
        self.assertEqual(str(self.app.host_entry["state"]), "disabled")
        self.assertEqual(str(self.viewer.zoom_in_button["state"]), "normal")
        before = self.viewer.scale
        self.viewer.zoom_in_button.invoke()
        self.root.update()
        self.assertGreater(self.viewer.scale, before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
