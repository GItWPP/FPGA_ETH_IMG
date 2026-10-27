"""Run the packaged Ethernet GUI's real worker and export flow against the board."""
import json
from pathlib import Path
import sys
import time
import tkinter as tk
from unittest.mock import patch

from band_client import BAND_LABEL
from hog_client import HOG_LABEL


def run(report_path, host, port, input_path, mode):
    import eth_image_gui
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = dict(status='running', frozen=bool(getattr(sys, 'frozen', False)),
                  host=host, port=port, input=str(input_path), mode=mode)
    errors = []
    root = tk.Tk()
    root.attributes('-alpha', 0.0)
    app = eth_image_gui.ImageApp(root)
    try:
        app.host.set(host)
        app.udp_port.set(str(port))
        app.mode.set({'band':BAND_LABEL, 'hog':HOG_LABEL, 'gamma':'Gamma 暗部提亮', 'copy':'原图回传'}[mode])
        app.load_image(input_path)
        with patch.object(eth_image_gui.messagebox, 'showerror', side_effect=lambda *args: errors.append(args)):
            gui_start = time.perf_counter()
            app.send()
            deadline = time.monotonic()+120
            while app.busy and time.monotonic() < deadline:
                root.update()
                time.sleep(0.01)
        gui_wait_seconds = time.perf_counter()-gui_start
        if app.busy or errors or app.result is None:
            raise RuntimeError(f'GUI failed: busy={app.busy}, errors={errors}, status={app.status.get()}')
        output = report_path.with_suffix('.png')
        app.result.save(output)
        app.left_image.actual_size()
        app.left_image.zoom(1.5)
        app.left_image.fit_image()
        if app.band_result:
            app.show_binary()
            root.update()
            from band_client import export_band
            export_band(app.result, app.band_result, output)
            report.update(words=app.band_result.words, bits=app.band_result.binary_rows())
        report.update(status='passed', gui_wait_seconds=gui_wait_seconds, gui_status=app.status.get(), output=str(output),
                      transfer_metrics=getattr(app,'last_transfer_metrics',None))
    except Exception as exc:
        report.update(status='failed', error=repr(exc), dialogs=errors)
    finally:
        for callback in root.tk.call('after', 'info'):
            root.after_cancel(callback)
        root.destroy()
        report_path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    return 0 if report['status']=='passed' else 1
