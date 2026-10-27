"""Exercise real PL response caching with deliberate request/reply loss and reorder."""
import hashlib
import json
from pathlib import Path
from eth_image import UdpImageClient
from uart_image import Decoder
from project_paths import ROOT


class FaultClient(UdpImageClient):
    def __init__(self, fault):
        super().__init__(timeout=0.03,window_size=64)
        self.fault = fault
        self.injected = False
        self.held = None

    def _send_datagram(self, encoded):
        packet = Decoder().feed(encoded)[0]
        if self.fault == 'drop_request' and packet.cmd == 3 and packet.seq == 2 and not self.injected:
            self.injected = True
            self.sent_datagrams += 1
            return
        if self.fault == 'reorder_request' and packet.cmd == 3 and packet.seq == 2 and not self.injected:
            self.injected = True
            self.held = encoded
            self.sent_datagrams += 1
            return
        super()._send_datagram(encoded)
        if self.held is not None and packet.cmd == 3 and packet.seq == 3:
            assert self.socket.send(self.held) == len(self.held)
            self.held = None

    def _decode_datagram(self, data, source):
        reply = super()._decode_datagram(data, source)
        if self.fault == 'drop_reply' and reply and reply.cmd == 0x83 and reply.seq == 1 and not self.injected:
            self.injected = True
            return None
        return reply


def main():
    raw = bytes(range(256))*520
    report = dict(status='running',cases=[],bitstream_sha256=hashlib.sha256((ROOT/'project_eth/build/eth_img.bit').read_bytes()).hexdigest())
    for fault in ('drop_request','drop_reply','reorder_request'):
        with FaultClient(fault) as client:
            result = client.transfer(raw,512,130,0)
            assert result == raw and client.injected and client.retry_count > 0
            assert client.active_window == 64 and client.window_peak == 64
            row=dict(fault=fault,status='passed',retries=client.retry_count,bytes=len(result))
            report['cases'].append(row)
            print(row,flush=True)
    report['status']='passed'
    output=ROOT/'tools/board_results_eth_window'
    output.mkdir(exist_ok=True)
    (output/'window_faults.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__':
    main()
