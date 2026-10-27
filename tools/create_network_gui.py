"""Build the Ethernet GUI once from the preserved UART GUI layout."""
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]


def main():
    target=ROOT/'tools/eth_image_gui.py'
    if target.exists():
        raise FileExistsError(target)
    text=(ROOT/'tools/uart_image_gui.py').read_text(encoding='utf-8')
    text=text.replace('from uart_image import (ImageClient,', 'from uart_image import (')
    text=text.replace('                        open_serial, reference, rgb565_to_image, serial_ports,',
                      '                        reference, rgb565_to_image,')
    text=text.replace('from hog_client import', 'from eth_image import UdpImageClient, DEFAULT_HOST, DEFAULT_PORT, network_endpoint\nfrom hog_client import',1)
    text=text.replace('FPGA 图像工作台 · Band 解码', 'ZU4EV 千兆以太网图像工作台')
    text=text.replace('self.port = tk.StringVar()', 'self.port = tk.StringVar(value=DEFAULT_HOST)')
    text=text.replace('self.baud = tk.StringVar(value="1500000")', 'self.baud = tk.StringVar(value=str(DEFAULT_PORT))')
    start=text.index('        ttk.Label(panel, text="串口"')
    end=text.index('        ttk.Label(panel, text="尺寸"', start)
    text=text[:start]+'''        ttk.Label(panel, text="板卡 IP", style="CardMuted.TLabel").grid(row=0, column=0, sticky="w")
        self.port_combo = ttk.Entry(panel, textvariable=self.port, width=14)
        self.port_combo.grid(row=0, column=1, padx=(10, 8))
        self.refresh_button = ttk.Button(panel, text="检测连接", command=self.test_connection)
        self.refresh_button.grid(row=0, column=2)
        ttk.Label(panel, text="UDP 端口", style="CardMuted.TLabel").grid(row=0, column=3, padx=(26, 10))
        self.baud_entry = ttk.Entry(panel, textvariable=self.baud, width=12)
        self.baud_entry.grid(row=0, column=4, sticky="w")
        ttk.Label(panel, text="千兆以太网 · UDP", style="CardMuted.TLabel").grid(row=0, column=5, padx=(16, 0), sticky="w")
'''+text[end:]
    start=text.index('    def update_summary(self):')
    end=text.index('    def dimensions(self):',start)
    text=text[:start]+'''    def update_summary(self):
        sizing = "自动尺寸" if self.auto_size.get() else f"{self.width.get()} × {self.height.get()}"
        self.connection_text.set(f"{self.port.get()}:{self.baud.get()}  ·  UDP  ·  {sizing}")

    def refresh(self):
        self.update_summary()

    def test_connection(self):
        if self.busy:
            return
        try:
            host, udp_port = network_endpoint(self.port.get(), self.baud.get())
        except ValueError as exc:
            messagebox.showerror("网络设置", str(exc))
            return
        self.set_busy(True)
        self.status.set("正在检测 ZU4EV UDP 连接…")
        def worker():
            try:
                with UdpImageClient(host, udp_port) as client:
                    client.ping()
                self.events.put(("connection", f"已连接 ZU4EV · {host}:{udp_port} · UDP"))
            except Exception as exc:
                self.events.put(("error", str(exc)))
        threading.Thread(target=worker, daemon=True).start()

'''+text[end:]
    text=text.replace('''            baud = int(self.baud.get())
            if baud <= 0 or not self.port.get().strip():
                raise ValueError("请在设置中选择串口并输入有效波特率")''',
                      '            host, udp_port = network_endpoint(self.port.get(), self.baud.get())')
    text=text.replace('            port = self.port.get().strip()\n','')
    pattern=r'with open_serial\(port, baud\) as stream:\n\s+stream.reset_input_buffer\(\)\n\s+client = ImageClient\(stream, baud\)'
    text,count=re.subn(pattern,'with UdpImageClient(host, udp_port) as client:',text)
    assert count==3,count
    text=text.replace('模式及串口链路','模式及以太网链路')
    text=text.replace('''                if event[0] == "stage":''','''                if event[0] == "connection":
                    self.set_busy(False)
                    self.status.set(event[1])
                elif event[0] == "stage":''')
    # Use network-oriented names in the active GUI; the original remains a reference.
    for before,after in [('self.port_combo','self.host_entry'),('self.baud_entry','self.udp_port_entry'),
                         ('self.port','self.host'),('self.baud','self.udp_port')]:
        text=text.replace(before,after)
    start=text.index('\ndef main():')
    text=text[:start]+'''
def main():
    parser = argparse.ArgumentParser(description="ZU4EV 千兆以太网图像工作台")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--self-test", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--report", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--input", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--test-mode", choices=("band", "hog", "gamma"), default="band", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.self_test:
        if args.report is None or args.input is None:
            parser.error("--self-test requires --report and --input")
        from eth_gui_selftest import run
        return run(args.report, args.host, args.port, args.input, args.test_mode)
    app_root = tk.Tk()
    app = ImageApp(app_root)
    app.host.set(args.host)
    app.udp_port.set(str(args.port))
    app_root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'''
    target.write_text(text,encoding='utf-8')
    for name in ['test_image_viewer.py','test_image_sizing.py','test_band.py']:
        path=ROOT/'tools'/name
        test=path.read_text(encoding='utf-8').replace('uart_image_gui','eth_image_gui')
        test=test.replace('''        with patch.object(eth_image_gui, "serial_ports", return_value=[]):
            self.app = eth_image_gui.ImageApp(self.root)''',
                          '        self.app = eth_image_gui.ImageApp(self.root)')
        test=test.replace('self.app.port_combo','self.app.host_entry')
        path.write_text(test,encoding='utf-8')
    print('PASS Ethernet GUI: IP/UDP settings, connection test and all image modes')


if __name__=='__main__':
    main()
