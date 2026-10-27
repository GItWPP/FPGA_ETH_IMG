"""Independent full Ethernet-frame expectations for burst/window recovery."""
from pathlib import Path
import struct
from generate_eth_vectors import ROOT, SLOT, udp
from uart_image import Packet, iter_filter_tiles, reference


def main():
    out = ROOT/'sim/window_vectors'
    out.mkdir(exist_ok=True)
    requests, responses, groups = [], [], []
    def group(items):
        start = len(requests)
        for request, response, options in items:
            requests.append(udp(request.encode(), **options))
            if response is not None:
                responses.append(udp(response.encode(), response=True, ip_id=len(responses), **options))
        groups.append((start,len(requests),len(responses)))
    def good(packet,payload=b'',**options):
        return packet,Packet(packet.cmd|0x80,packet.transfer_id,packet.seq,payload),options
    def error(packet,code,**options):
        return packet,Packet(0xff,packet.transfer_id,packet.seq,bytes([code])),options
    def image(mode,width,height,tid):
        raw = struct.pack(f'<{width*height}H',*((i*573+109)&65535 for i in range(width*height)))
        output = reference(raw,mode,width,height)
        chunks = list(iter_filter_tiles(raw,width,height)) if mode in (3,4,5,7) else [(raw[n:n+1024],min(1024,len(raw)-n)) for n in range(0,len(raw),1024)]
        packets = [None]
        expected = [None]
        offset = 0
        for seq,(payload,count) in enumerate(chunks,1):
            packets.append(Packet(3,tid,seq,payload))
            expected.append(output[offset:offset+count])
            offset += count
        return Packet(2,tid,0,struct.pack('<HHBB',width,height,1,mode)),packets,expected
    group([good(Packet(5),b'EWIN\x01\x40\x00\x04')])
    start, packets, expected = image(0,512,12,71)
    group([good(start)])
    group([good(packets[n],expected[n]) for n in range(1,9)])
    group([good(packets[1],expected[1])])  # lost response for the oldest window slot
    # Invalid lookahead aliases slot 1; it must not corrupt the cached packet 1.
    lookahead = Packet(3,71,65,bytes(b ^ 0xff for b in packets[1].payload))
    group([error(lookahead,4),good(packets[1],expected[1])])
    conflict = Packet(3,71,1,bytes([packets[1].payload[0]^1])+packets[1].payload[1:])
    group([error(conflict,6), error(packets[1],4,peer=(bytes.fromhex('020000000018'),bytes([192,168,1,18]),49153)),
           good(packets[1],expected[1])])
    group([good(packets[9],expected[9]), error(packets[11],4), good(packets[10],expected[10]),
           good(packets[11],expected[11]), good(packets[12],expected[12])])
    group([error(Packet(2,72,0,struct.pack('<HHBB',0,12,1,0)),2), good(packets[9],expected[9]), good(packets[10],expected[10])])
    group([good(Packet(4,71,13)), error(packets[9],3)])
    for mode,width,height,tid in [(1,512,8,81),(3,7,8,82)]:
        start,packets,expected = image(mode,width,height,tid)
        group([good(start)])
        group([good(packets[n],expected[n]) for n in range(1,9)])
        group([good(packets[1],expected[1]),good(packets[7],expected[7])])
        group([good(Packet(4,tid,9))])
    # Two complete 64-packet bursts cross every cache slot and then wrap.
    start, packets, expected = image(0,512,130,91)
    group([good(start)])
    group([good(packets[n],expected[n]) for n in range(1,65)])
    group([good(packets[1],expected[1])])
    # Same physical-slot collision after a full window, with a malformed odd length.
    group([error(Packet(3,91,129,b'\xa7'*1023),4),good(packets[1],expected[1])])
    group([good(packets[n],expected[n]) for n in range(65,129)])
    group([good(packets[65],expected[65]),good(packets[129],expected[129]),good(packets[130],expected[130])])
    group([good(Packet(4,91,131))])
    # Distinct endpoints within the same pipelined burst retain their own replies.
    start, packets, expected = image(0,512,8,101)
    group([good(start)])
    peers = [(bytes.fromhex('020000000018'),bytes([192,168,1,18]),49152+n) for n in range(8)]
    group([good(packets[n],expected[n],peer=peers[n-1]) for n in range(1,9)])
    group([good(packets[3],expected[3],peer=peers[2])])
    group([good(Packet(4,101,9))])
    config = [f'localparam integer REQUEST_COUNT = {len(requests)};',
              f'localparam integer RESPONSE_COUNT = {len(responses)};',
              f'localparam integer GROUP_COUNT = {len(groups)};']
    (out/'count.vh').write_text('\n'.join(config)+'\n',encoding='ascii')
    init = ['initial begin']
    for name,frames in [('request',requests),('response',responses)]:
        for index,frame in enumerate(frames):
            init.append(f'    {name}_length[{index}] = {len(frame)};')
        (out/f'{name}s.mem').write_text(''.join(f'{b:02x}\n' for frame in frames for b in frame+bytes(SLOT-len(frame))),encoding='ascii')
    for index,(start,end,target) in enumerate(groups):
        init.extend([f'    group_start[{index}] = {start};', f'    group_end[{index}] = {end};', f'    group_target[{index}] = {target};'])
    (out/'cases.vh').write_text('\n'.join(init+['end'])+'\n',encoding='ascii')
    print(f'PASS window vectors: {len(groups)} bursts, {len(requests)} requests, {len(responses)} replies')
    lengths = (0,1,2,17,1024,1023,2)
    fast = [Packet(0x83,0x1234,index,bytes((n*7+index*13)&255 for n in range(length))).encode()
            for index,length in enumerate(lengths)]
    (out/'fast.mem').write_text(''.join(f'{b:02x}\n' for frame in fast for b in frame+bytes(SLOT-len(frame))),encoding='ascii')


if __name__ == '__main__':
    main()
