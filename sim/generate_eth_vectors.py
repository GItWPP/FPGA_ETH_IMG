"""Independent wire-frame vectors: Ethernet FCS/IP/UDP plus every image command."""
from pathlib import Path
import binascii
import json
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
from uart_image import Packet, FILTER_MODES, iter_filter_tiles, reference
from hog_model import MODEL_ID
from hog_reference import detect_reference
from generate_band_vectors import synthetic
from band_reference import decode_integer

LOCAL_MAC = bytes.fromhex('0255494d4704')
LOCAL_IP = bytes([192,168,1,12])
PC_MAC = bytes.fromhex('020000000018')
PC_IP = bytes([192,168,1,18])
PREAMBLE = b'\x55'*7+b'\xd5'
SLOT = 2048


def checksum(data):
    data += b'\0'*(len(data)%2)
    value = sum(struct.unpack(f'!{len(data)//2}H',data))
    while value >> 16:
        value = (value & 65535)+(value >> 16)
    return (~value)&65535


def ethernet(data, destination, source, kind):
    frame = destination+source+struct.pack('!H',kind)+data
    frame += bytes(max(0,60-len(frame)))
    return PREAMBLE+frame+struct.pack('<I',binascii.crc32(frame))


def udp(data, *, response=False, ip_id=0, peer=(PC_MAC,PC_IP,49152),
        dst_ip=None, dst_mac=None, dst_port=None, zero_checksum=False, fragment=0x4000):
    mac, ip, port = peer
    source_ip, target_ip = (LOCAL_IP,ip) if response else (ip,LOCAL_IP)
    target_ip = target_ip if dst_ip is None else dst_ip
    source_port, target_port = (1234,port) if response else (port,1234)
    target_port = target_port if dst_port is None else dst_port
    length = 8+len(data)
    udp_header=struct.pack('!HHHH',source_port,target_port,length,0)
    pseudo=source_ip+target_ip+bytes([0,17])+struct.pack('!H',length)
    udp_crc=0 if zero_checksum else (checksum(pseudo+udp_header+data) or 65535)
    udp_header=udp_header[:6]+struct.pack('!H',udp_crc)
    ip_header=struct.pack('!BBHHHBBH4s4s',0x45,0,20+length,ip_id,fragment,64,17,0,source_ip,target_ip)
    ip_header=ip_header[:10]+struct.pack('!H',checksum(ip_header))+ip_header[12:]
    source_mac, target_mac = (LOCAL_MAC,mac) if response else (mac,LOCAL_MAC)
    target_mac=target_mac if dst_mac is None else dst_mac
    return ethernet(ip_header+udp_header+data,target_mac,source_mac,0x800)


def recalculate_fcs(wire):
    return wire[:-4]+struct.pack('<I',binascii.crc32(wire[8:-4]))


def main():
    out=ROOT/'sim/eth_vectors'
    out.mkdir(exist_ok=True)
    cases=[]
    ip_id=0
    def add(name, request, reply=None, *, peer=(PC_MAC,PC_IP,49152), wire=None, response_wire=None, rx_error=False, **options):
        nonlocal ip_id
        request_wire = udp(request.encode() if isinstance(request,Packet) else request,peer=peer,**options) if wire is None else wire
        expected = response_wire
        if reply is not None:
            expected=udp(reply.encode(),response=True,ip_id=ip_id,peer=peer)
            ip_id+=1
        cases.append(dict(name=name,request=request_wire,response=expected or b'',rx_error=rx_error))
    def exchange(name,packet,payload=b'',**options):
        add(name,packet,Packet(packet.cmd|0x80,packet.transfer_id,packet.seq,payload),**options)

    arp_request=struct.pack('!HHBBH6s4s6s4s',1,0x800,6,4,1,PC_MAC,PC_IP,bytes(6),LOCAL_IP)
    arp_reply=struct.pack('!HHBBH6s4s6s4s',1,0x800,6,4,2,LOCAL_MAC,LOCAL_IP,PC_MAC,PC_IP)
    add('ARP broadcast request/reply',b'',wire=ethernet(arp_request,b'\xff'*6,PC_MAC,0x806),
        response_wire=ethernet(arp_reply,PC_MAC,LOCAL_MAC,0x806))
    ping=Packet(1)
    capabilities=b'UIMG\x01\xff\x00\x04'
    exchange('PING',ping,capabilities)
    exchange('Peer address changes are bound to each request',ping,capabilities,
             peer=(bytes.fromhex('020000000019'),bytes([192,168,1,19]),54321))
    exchange('IPv4 accepts disabled UDP checksum',ping,capabilities,zero_checksum=True)
    clean=udp(ping.encode())
    bad=bytearray(clean)
    bad[-1]^=1
    add('Bad Ethernet FCS discarded',b'',wire=bytes(bad))
    for name,index in [('Bad IPv4 checksum discarded',8+14+10),('Bad UDP checksum discarded',8+14+20+6)]:
        bad=bytearray(clean)
        bad[index]^=1
        add(name,b'',wire=recalculate_fcs(bytes(bad)))
    bad=bytearray(ping.encode())
    bad[-1]^=1
    add('Bad application CRC discarded',bytes(bad))
    add('Truncated application packet discarded',ping.encode()[:-1])
    add('Two application packets in one datagram discarded',ping.encode()*2)
    add('Wrong destination IP discarded',ping,dst_ip=bytes([192,168,1,13]))
    add('Wrong destination MAC discarded',ping,dst_mac=bytes.fromhex('020000000077'))
    add('Wrong destination UDP port discarded',ping,dst_port=1235)
    add('IPv4 fragment discarded',ping,fragment=0x2000)
    add('RGMII receive error discarded',ping,rx_error=True)
    exchange('Valid packet recovers after all invalid inputs',ping,capabilities)
    add('Unknown command returns protocol error',Packet(0x70,21,3),Packet(0xff,21,3,b'\x01'))

    for mode in range(8):
        width,height=(7,3) if mode in FILTER_MODES else (512,1)
        pixels=struct.pack(f'<{width*height}H',*((i*573+109)&65535 for i in range(width*height)))
        expected=reference(pixels,mode,width,height)
        tid=400+mode
        exchange(f'Mode {mode} START',Packet(2,tid,0,struct.pack('<HHBB',width,height,1,mode)))
        chunks=list(iter_filter_tiles(pixels,width,height)) if mode in FILTER_MODES else [(pixels,len(pixels))]
        offset=0
        for seq,(payload,count) in enumerate(chunks,1):
            packet=Packet(3,tid,seq,payload)
            response=expected[offset:offset+count]
            exchange(f'Mode {mode} DATA {seq}',packet,response)
            if seq==1:
                exchange(f'Mode {mode} identical DATA retry',packet,response)
                conflict=Packet(3,tid,seq,payload[:-1]+bytes([payload[-1]^1]))
                add(f'Mode {mode} conflicting retry rejected',conflict,Packet(0xff,tid,seq,b'\x06'))
            offset+=count
        end=Packet(4,tid,len(chunks)+1)
        exchange(f'Mode {mode} END',end)
        exchange(f'Mode {mode} END retry',end)

    exchange('HOG INFO',Packet(0x1f),struct.pack('<4sHHBBBBI',b'HOG1',320,240,64,128,8,1,MODEL_ID))
    tid=801
    gray=bytes(76800)
    exchange('HOG START',Packet(0x10,tid,0))
    seq=1
    for offset in range(0,len(gray),1024):
        exchange(f'HOG DATA {seq}',Packet(0x11,tid,seq,gray[offset:offset+1024]))
        seq+=1
    run=Packet(0x12,tid,seq)
    exchange('HOG RUN',run,struct.pack('<H',495))
    exchange('HOG RUN retry',run,struct.pack('<H',495))
    seq+=1
    scores=detect_reference(gray)
    for offset in range(0,495,256):
        count=min(256,495-offset)
        exchange('HOG READ',Packet(0x13,tid,seq,struct.pack('<HH',offset,count)),struct.pack(f'<{count}i',*scores[offset:offset+count]))
        seq+=1

    image,truth=synthetic()
    result=decode_integer(image)
    height,width=image.shape
    exchange('Band INFO',Packet(0x2f),struct.pack('<4sHHBBHI',b'BND1',512,512,1,2,4096,0))
    tid=901
    exchange('Band START',Packet(0x20,tid,0,struct.pack('<HH',width,height)))
    seq=1
    gray=image.tobytes()
    for offset in range(0,len(gray),1024):
        exchange(f'Band DATA {seq}',Packet(0x21,tid,seq,gray[offset:offset+1024]))
        seq+=1
    info=struct.pack('<4sHBBHHHH',b'BND1',len(result['cells']),result['rows'],result['status'],result['pitch_q8'],width,height,result['dots'])
    run=Packet(0x22,tid,seq)
    exchange('Band RUN',run,info)
    exchange('Band RUN retry',run,info)
    seq+=1
    for offset in range(0,len(result['cells']),256):
        cells=result['cells'][offset:offset+256]
        exchange('Band READ',Packet(0x23,tid,seq,struct.pack('<HH',offset,len(cells))),struct.pack(f'<{len(cells)}I',*cells))
        seq+=1

    (out/'count.vh').write_text(f'localparam integer CASE_COUNT = {len(cases)};\n',encoding='ascii')
    includes=['initial begin']
    requests=[]
    responses=[]
    for index,item in enumerate(cases):
        assert len(item['request'])<=SLOT and len(item['response'])<=SLOT
        requests.extend(item['request']+bytes(SLOT-len(item['request'])))
        responses.extend(item['response']+bytes(SLOT-len(item['response'])))
        includes.extend([f'    request_length[{index}] = {len(item["request"])};',
                         f'    response_length[{index}] = {len(item["response"])};',
                         f'    inject_error[{index}] = 1\'b{int(item["rx_error"])};'])
    includes.append('end')
    (out/'cases.vh').write_text('\n'.join(includes)+'\n',encoding='ascii')
    (out/'requests.mem').write_text(''.join(f'{v:02x}\n' for v in requests),encoding='ascii')
    (out/'responses.mem').write_text(''.join(f'{v:02x}\n' for v in responses),encoding='ascii')
    (out/'manifest.json').write_text(json.dumps([dict(name=c['name'],request_bytes=len(c['request']),response_bytes=len(c['response'])) for c in cases],indent=2)+'\n',encoding='utf-8')
    print(f'PASS Ethernet vectors: {len(cases)} wire transactions, eight modes, HOG and Band')


if __name__=='__main__':
    main()
