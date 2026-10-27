"""Independent scalar Sobel expectations for the new byte-stream protocol."""
from pathlib import Path
import struct
from generate_eth_vectors import ROOT,SLOT,udp
from uart_image import Packet


def sobel_reference(raw,width,height):
    pixels=struct.unpack(f'<{width*height}H',raw)
    gray=[]
    for p in pixels:
        r,g,b=p>>11,(p>>5)&63,p&31
        gray.append((77*((r<<3)|(r>>2))+150*((g<<2)|(g>>4))+29*((b<<3)|(b>>2)))>>8)
    result=bytearray()
    for y in range(height):
        for x in range(width):
            n=[gray[min(height-1,max(0,y+dy))*width+min(width-1,max(0,x+dx))]
               for dy in (-1,0,1) for dx in (-1,0,1)]
            gx=n[2]+2*n[5]+n[8]-n[0]-2*n[3]-n[6]
            gy=n[6]+2*n[7]+n[8]-n[0]-2*n[1]-n[2]
            result.append(min(255,abs(gx)+abs(gy)))
    return bytes(result)


def main():
    out=ROOT/'sim/stream_vectors';out.mkdir(exist_ok=True)
    requests,responses,groups=[],[],[]
    def good(p,payload=b'',**options):
        return p,Packet(p.cmd|128,p.transfer_id,p.seq,payload),options
    def error(p,code,**options):
        return p,Packet(255,p.transfer_id,p.seq,bytes([code])),options
    def group(items):
        start=len(requests)
        for req,resp,opts in items:
            requests.append(udp(req.encode(),**opts))
            responses.append(udp(resp.encode(),response=True,ip_id=len(responses),**opts))
        groups.append((start,len(requests),len(responses)))
    group([error(Packet(0x40,1,0,b''),2)])
    for tid,(w,h) in enumerate([(1,1),(1,11),(11,1),(7,9),(1920,3),(257,140)],195):
        raw=struct.pack(f'<{w*h}H',*((i*31+(i//w)*61+123)&65535 for i in range(w*h)))
        ref=sobel_reference(raw,w,h)
        padded=b''.join(raw[min(y,h-1)*w*2:(min(y,h-1)+1)*w*2]+raw[(min(y,h-1)+1)*w*2-2:(min(y,h-1)+1)*w*2] for y in range(h+1))
        start=Packet(0x40,tid,0,struct.pack('<HHBB',w,h,1,5))
        info=b'SBL1'+struct.pack('<HH',w,h)
        group([good(start,info),good(start,info)])
        group([error(Packet(0x40,tid,0,struct.pack('<HHBB',0,h,1,5)),6)])
        packets=[];offset=0
        for seq,pos in enumerate(range(0,len(padded),1024),1):
            payload=padded[pos:pos+1024]
            first,last=pos//2,(pos+len(payload))//2
            count=sum(1 for i in range(first,last) if i%(w+1)>0 and i//(w+1)>0)
            packet=Packet(0x41,tid,seq,payload)
            packets.append(good(packet,ref[offset:offset+count]));offset+=count
        assert offset==len(ref)
        group(packets[:64])
        if len(packets)>64:
            look=Packet(0x41,tid,129,b'\x7f'*1024)
            group([error(look,4),packets[0]])
            group(packets[64:])
        group([packets[-1]])
        bad=Packet(0x41,tid,packets[-1][0].seq,bytes([packets[-1][0].payload[0]^1])+packets[-1][0].payload[1:])
        group([error(bad,6),packets[-1]])
        seq=len(packets)+1
        peer=(bytes.fromhex('020000000018'),bytes([192,168,1,18]),49299)
        group([error(Packet(0x41,tid,seq,b'12'),3,peer=peer),error(Packet(0x41,tid,seq,b'1'),5)])
        end=Packet(0x42,tid,seq)
        group([good(end,struct.pack('<I',w*h)),good(end,struct.pack('<I',w*h))])
    group([good(Packet(1),b'UIMG\x01\x80\x07\x38\x04\x00\x04')])
    # Keep legacy-path checks in their existing independent 18-suite regression.
    groups.pop();requests.pop();responses.pop()
    (out/'count.vh').write_text(f'localparam integer REQUEST_COUNT = {len(requests)};\nlocalparam integer RESPONSE_COUNT = {len(responses)};\nlocalparam integer GROUP_COUNT = {len(groups)};\n',encoding='ascii')
    init=['initial begin']
    for name,frames in [('request',requests),('response',responses)]:
        for i,frame in enumerate(frames):init.append(f'    {name}_length[{i}] = {len(frame)};')
        (out/f'{name}s.mem').write_text(''.join(f'{b:02x}\n' for frame in frames for b in frame+bytes(SLOT-len(frame))),encoding='ascii')
    for i,(start,end,target) in enumerate(groups):
        init.extend([f'    group_start[{i}] = {start};',f'    group_end[{i}] = {end};',f'    group_target[{i}] = {target};'])
    (out/'cases.vh').write_text('\n'.join(init+['end'])+'\n',encoding='ascii')
    print('PASS stream vectors',len(requests),'requests')

if __name__=='__main__':main()
