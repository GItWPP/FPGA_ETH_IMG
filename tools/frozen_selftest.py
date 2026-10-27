"""Exercise the real file loader and GUI worker in the frozen executable."""
import json
from pathlib import Path
import sys
import time
import traceback

from PIL import Image
from uart_image import (Packet, Decoder, MODE_LABELS, crc16, image_to_rgb565, reference,
                        serial_ports, prepare_image)


def run(report_path, port=None, width=128, height=128, auto_suite=False, filter_suite=False, enhance_suite=False):
    import tkinter as tk
    from uart_image_gui import ImageApp
    report_path = Path(report_path).resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    inputs = report_path.parent / "inputs"
    inputs.mkdir(exist_ok=True)
    report = {"status": "running", "frozen": bool(getattr(sys, "frozen", False)),
              "executable": sys.executable, "serial_ports": serial_ports(), "transfers": []}
    root = None

    def save_report():
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    try:
        assert crc16(b"123456789") == 0x29B1
        packet = Packet(3, 42, 1, b"\x00\xf8")
        decoder = Decoder()
        decoded = []
        for value in packet.encode():
            decoded.extend(decoder.feed(bytes([value])))
        assert decoded == [packet]
        root = tk.Tk()
        root.attributes("-alpha", 0.0)
        app = ImageApp(root)
        root.update()
        import uart_image_gui
        uart_image_gui.messagebox.showerror = lambda title, message: report.update(gui_error=f"{title}: {message}")
        pattern = Image.new("RGB", (128, 128))
        pattern.putdata([((x * 2) & 255, (y * 2) & 255, ((x + y) * 3) & 255)
                        for y in range(128) for x in range(128)])
        assert app.auto_size.get()
        assert app.size_preset.get() == "自动识别原图"
        assert not app.settings_panel.winfo_ismapped()
        report["view_checks"] = []

        def exercise_viewer(viewer, label):
            if viewer.image is None:
                raise AssertionError("viewer has no image")
            source_size, source_pixels = app.source.size, app.source.tobytes()
            send_size = app.dimensions()
            viewer.actual_size()
            root.update()
            cx, cy = (value // 2 for value in viewer.viewport_size())
            before = viewer.image_point(cx, cy)
            viewer.canvas.event_generate("<MouseWheel>", x=cx, y=cy, delta=120)
            root.update()
            after = viewer.image_point(cx, cy)
            assert viewer.scale > 1
            assert abs(before[0] - after[0]) < 0.001 and abs(before[1] - after[1]) < 0.001
            viewer.canvas.event_generate("<ButtonPress-1>", x=cx, y=cy)
            viewer.canvas.event_generate("<B1-Motion>", x=cx + 16, y=cy + 8)
            viewer.canvas.event_generate("<ButtonRelease-1>", x=cx + 16, y=cy + 8)
            root.update()
            viewer.zoom(1e6)
            root.update()
            viewport = viewer.viewport_size()
            assert viewer.rendered_size[0] <= viewport[0] + 2 * viewer.MAX_SCALE
            assert viewer.rendered_size[1] <= viewport[1] + 2 * viewer.MAX_SCALE
            viewer.fit_button.invoke()
            root.update()
            assert viewer.fit_mode
            assert app.dimensions() == send_size
            assert app.source.size == source_size and app.source.tobytes() == source_pixels
            report["view_checks"].append(label)

        def load_native(size):
            path = inputs / f"source_{size[0]}x{size[1]}.png"
            pattern.resize(size, Image.Resampling.NEAREST).save(path)
            # Opening each file must replace any previous width/height values.
            app.width.set("128")
            app.height.set("128")
            app.load_image(path)
            assert app.auto_size.get()
            assert app.dimensions() == size
            assert app.source.size == size
            assert app.result is None
            return path

        if auto_suite:
            load_native((1920, 1080))
            assert len(image_to_rgb565(prepare_image(app.source))) == 4147200
            report["native_1080p_file_detection"] = "PASS"
            oversized = inputs / "oversized_1921x100.png"
            Image.new("RGB", (1921, 100)).save(oversized)
            app.load_image(oversized)
            try:
                app.dimensions()
            except ValueError:
                report["oversize_rejection"] = "PASS"
            else:
                raise AssertionError("oversize auto image was accepted")
            sizes = [(17, 19), (321, 213), (479, 803), (1920, 1), (1, 1080)]
        elif enhance_suite:
            sizes = [(1, 1), (17, 19), (321, 213), (1920, 1), (1, 1080)]
        elif filter_suite:
            sizes = [(1, 1), (1, 17), (19, 1), (169, 3), (321, 23), (479, 41), (1920, 1), (1, 1080)]
        else:
            sizes = [(width, height)]

        def transfer_case(mode, input_size, sizing):
            names = tuple(MODE_LABELS)
            app.mode.set(names[mode])
            target_size = app.dimensions()
            data = image_to_rgb565(prepare_image(app.source, *target_size))
            app.send()
            # Include halo traffic, USB packet latency and the full-image reference.
            deadline = time.monotonic() + max(30, len(data) * (120 if mode in (3, 4, 5, 7) else 40) / 1_500_000 + 90)
            next_report = 0.0
            while app.busy and time.monotonic() < deadline:
                root.update()
                if time.monotonic() >= next_report:
                    report["active_mode"] = mode
                    report["active_size"] = list(target_size)
                    report["progress_percent"] = round(float(app.progress["value"]), 2)
                    report["progress_text"] = app.status.get()
                    save_report()
                    next_report = time.monotonic() + 1
                time.sleep(0.01)
            if app.busy or app.result is None:
                raise RuntimeError(report.get("gui_error", "GUI transfer did not finish"))
            assert image_to_rgb565(app.result) == reference(data, mode, *target_size)
            assert app.result.size == target_size
            if enhance_suite:
                exercise_viewer(app.right_image, f"result mode {mode} {target_size}")
            image_name = f"{sizing}_{target_size[0]}x{target_size[1]}_mode_{mode}.png"
            app.result.save(report_path.parent / image_name)
            report["transfers"].append({"mode": mode, "sizing": sizing, "input_size": list(input_size),
                                        "width": target_size[0], "height": target_size[1],
                                        "bytes": len(data), "status": app.status.get(),
                                        "image": image_name, "compare": "PASS"})
            save_report()

        app.port.set(port or "")
        app.baud.set("1500000")
        for size in sizes:
            load_native(size)
            root.update_idletasks()
            if enhance_suite:
                exercise_viewer(app.left_image, f"source {size}")
            if port:
                for mode in ((6, 7) if enhance_suite else (range(3, 6) if filter_suite else range(3))):
                    transfer_case(mode, size, "auto")
        if filter_suite and port:
            load_native((17, 19))
            for mode in range(3):
                transfer_case(mode, (17, 19), "regression")
        if enhance_suite:
            app.toggle_settings()
            root.update()
            assert app.settings_panel.winfo_ismapped()
            app.toggle_settings()
            root.update()
            assert not app.settings_panel.winfo_ismapped()
            if port:
                load_native((17, 19))
                for mode in range(6):
                    transfer_case(mode, (17, 19), "regression")
        if auto_suite:
            load_native((321, 213))
            app.size_preset.set("128×128")
            app.select_preset()
            assert not app.auto_size.get()
            assert app.dimensions() == (128, 128)
            if port:
                transfer_case(1, (321, 213), "manual")
            app.use_original_size()
            assert app.auto_size.get() and app.dimensions() == (321, 213)
            report["manual_resize_and_return_to_auto"] = "PASS"
        report["status"] = "PASS"
        for field in ("active_mode", "active_size", "progress_percent", "progress_text"):
            report.pop(field, None)
        report["checks"] = ["CRC", "packet decoding", "Tk/Tcl runtime", "Pillow", "serial enumeration",
                            "default auto sizing", "real PNG file loading", "consecutive native sizes", "GUI preview"]
        return 0
    except Exception as exc:
        report["status"] = "FAIL"
        report["error"] = f"{type(exc).__name__}: {exc}"
        report["traceback"] = traceback.format_exc()
        return 1
    finally:
        if root is not None:
            root.destroy()
        save_report()
