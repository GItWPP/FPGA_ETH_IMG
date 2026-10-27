"""Physical UDP HOG and modular-image regression, with integer score comparisons."""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import time
from PIL import Image
from uart_image import Packet,ProtocolError,image_to_rgb565,reference
from eth_image import UdpImageClient, DEFAULT_HOST, DEFAULT_PORT
from hog_client import HOGClient,prepare_hog,draw_detections
from hog_reference import detect_reference
from hog_model import MODEL_ID
from project_paths import user_test_images


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host',default=DEFAULT_HOST)
    parser.add_argument('--port',type=int,default=DEFAULT_PORT)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--user-images',action='store_true',help='Use all test_img pictures instead of the HOG group')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    out=args.output.resolve() if args.output else root/'tools/board_results_eth_hog'
    out.mkdir(parents=True,exist_ok=True)
    report={'status':'running','host':args.host,'port':args.port,'model_id':f'{MODEL_ID:08X}',
            'bitstream_sha256':hashlib.sha256((root/'project_eth/build/eth_img.bit').read_bytes()).hexdigest(),
            'image_transfers':[],'hog_frames':[]}
    def save(): (out/'board_hog_test.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    try:
        with UdpImageClient(args.host,args.port) as client:
            report['ping']=client.ping().hex()
            report['hog_info']=HOGClient(client).info().hex()
            print('PASS FPGA HOG INFO',report['hog_info'],flush=True)
            def reject(packet,code):
                try: client.transact(packet,0)
                except ProtocolError as exc:
                    assert f'error {code}:' in str(exc),(code,str(exc))
                else: raise AssertionError('illegal request accepted')
            # Preserve image result across a rejected HOG command, then invalidate image session on HOG START.
            client.transact(Packet(2,900,0,struct.pack('<HHBB',2,1,1,0)),0)
            image_packet=Packet(3,900,1,bytes.fromhex('12ab34cd'))
            assert client.transact(image_packet,4).payload==image_packet.payload
            reject(Packet(0x1e,901),1)
            assert client.transact(image_packet,4).payload==image_packet.payload
            client.transact(Packet(0x10,902,0),0)
            reject(Packet(3,900,2,b'xx'),3)
            reject(Packet(0x12,902,1),5)
            reject(Packet(0x11,903,1,b'x'),3)
            reject(Packet(0x11,902,2,b'x'),4)
            reject(Packet(0x11,902,1),5)
            report['cross_cache_and_errors']='passed'
            paths=user_test_images(None if args.user_images else 'hog')
            # Application photographs always come from test_img; synthetic frames cover arithmetic/reset.
            images=[Image.open(path).convert('RGB') for path in paths]
            pattern=Image.new('L',(320,240))
            pattern.putdata([(x*37+y*61+(x*y)%251)&255 for y in range(240) for x in range(320)])
            images.extend([pattern,Image.new('L',(320,240),127)])
            names=[path.relative_to(root).as_posix() for path in paths]+['stress_pattern','uniform']
            for number,image in enumerate(images):
                gray,geometry=prepare_hog(image)
                start=time.monotonic()
                hog=HOGClient(client)
                scores=hog.detect(gray,transfer_id=1000+number)
                uart_elapsed=time.monotonic()-start
                expected=detect_reference(gray)
                assert scores==expected,[(i,a,b) for i,(a,b) in enumerate(zip(scores,expected)) if a!=b][:3]
                annotated,boxes=draw_detections(image,scores,geometry)
                annotated.save(out/f'hog_{number}_result.png')
                (out/f'hog_{number}_scores.json').write_text(json.dumps(scores),encoding='utf-8')
                report['hog_frames'].append({'case':number,'input':names[number],
                    'scores_compared':len(scores),'boxes':boxes,'uart_seconds':uart_elapsed,'run_command_seconds':hog.calculation_seconds,
                    'retries_so_far':client.retry_count})
                save()
                print('PASS board HOG',number,'495 scores, boxes',len(boxes),'UDP seconds',round(uart_elapsed,3),flush=True)
            # Real RUN/READ retry and cross-algorithm invalid request must not overwrite score cache.
            final_tid=1000+len(images)-1
            read=Packet(0x13,final_tid,78,struct.pack('<HH',256,239))
            cached=client.transact(read,956).payload
            reject(Packet(2,1100,0,b''),2)
            assert client.transact(read,956).payload==cached
            reject(Packet(0x13,final_tid,79,struct.pack('<HH',494,2)),2)
            assert client.transact(read,956).payload==cached
            # Each independent legacy algorithm: native edge geometry plus an odd, multi-tile frame.
            for width,height in [(1,1),(169,3),(321,17)]:
                image=Image.new('RGB',(width,height))
                image.putdata([((x*53+y*7)&255,(x*17+y*71)&255,(x*97+y*11)&255) for y in range(height) for x in range(width)])
                raw=image_to_rgb565(image)
                for mode in range(8):
                    start=time.monotonic()
                    actual=client.transfer(raw,width,height,mode)
                    assert actual==reference(raw,mode,width,height),(width,height,mode)
                    report['image_transfers'].append({'size':[width,height],'mode':mode,'bytes':len(raw),'seconds':time.monotonic()-start})
                print('PASS board eight modular algorithms',width,height,flush=True)
                save()
            report.update(status='passed',retry_count=client.retry_count)
    except Exception as exc:
        report.update(status='failed',error=repr(exc))
        save()
        raise
    save()
    print('PASS physical board HOG and modular image regression',flush=True)


if __name__=='__main__': main()
