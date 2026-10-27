"""HOG protocol, letterbox geometry and display; features/classifier run in FPGA."""
from __future__ import annotations
import secrets
import struct
import time
from PIL import Image, ImageDraw
from uart_image import Packet, ProtocolError
from hog_reference import FRAME_WIDTH, FRAME_HEIGHT, SCORE_COUNT, nms, detect_reference
from hog_model import MODEL_ID, THRESHOLD, SCORE_SHIFT

HOG_LABEL='HOG 行人检测（单尺度）'


def prepare_hog(image):
    width,height=image.size
    if width<1 or height<1: raise ValueError('empty image')
    scale=min(FRAME_WIDTH/width,FRAME_HEIGHT/height)
    target=(max(1,round(width*scale)),max(1,round(height*scale)))
    target=(min(320,target[0]),min(240,target[1]))
    x,y=(320-target[0])//2,(240-target[1])//2
    frame=Image.new('L',(320,240),0)
    frame.paste(image.convert('L').resize(target,Image.Resampling.LANCZOS),(x,y))
    return frame.tobytes(),(x,y,target[0],target[1],width,height)


def map_boxes(scores,geometry,threshold=THRESHOLD):
    px,py,tw,th,width,height=geometry
    result=[]
    for x,y,w,h,score in nms(scores,threshold):
        # Discard candidates dominated by padding, then clip to the actual source.
        left,top=max(x,px),max(y,py)
        right,bottom=min(x+w,px+tw),min(y+h,py+th)
        if max(0,right-left)*max(0,bottom-top)<w*h*0.6: continue
        box=(max(0,round((left-px)*width/tw)),max(0,round((top-py)*height/th)),
             min(width,round((right-px)*width/tw)),min(height,round((bottom-py)*height/th)))
        if box[2]>box[0] and box[3]>box[1]: result.append((*box,score))
    return result


def draw_detections(image,scores,geometry,threshold=THRESHOLD):
    result=image.convert('RGB').copy()
    draw=ImageDraw.Draw(result)
    boxes=map_boxes(scores,geometry,threshold)
    stroke=max(2,round(max(image.size)/400))
    for x0,y0,x1,y1,score in boxes:
        draw.rectangle((x0,y0,x1-1,y1-1),outline=(24,211,150),width=stroke)
        label=f'person {score/(1<<SCORE_SHIFT):+.2f}'
        bounds=draw.textbbox((x0,y0),label)
        draw.rectangle((bounds[0],bounds[1],bounds[2]+4,bounds[3]+2),fill=(15,39,40))
        draw.text((x0+2,y0),label,fill='white')
    return result,boxes


class HOGClient:
    def __init__(self,client): self.client=client

    def info(self):
        payload=self.client.transact(Packet(0x1f),16).payload
        magic,width,height,ww,wh,stride,version,model=struct.unpack('<4sHHBBBBI',payload)
        if (magic,width,height,ww,wh,stride,version)!=(b'HOG1',320,240,64,128,8,1):
            raise ProtocolError('FPGA HOG接口版本不兼容，请下载对应bitstream')
        if model!=MODEL_ID:
            raise ProtocolError(f'FPGA模型{model:08X}与上位机{MODEL_ID:08X}不一致，请更新bitstream或上位机')
        return payload

    def detect(self,gray:bytes,progress=None,stage=None,transfer_id=None):
        if len(gray)!=76800: raise ValueError('HOG requires exactly 320×240 gray8')
        self.info()
        transfer_id=secrets.randbelow(65536) if transfer_id is None else transfer_id
        self.client.transact(Packet(0x10,transfer_id,0),0)
        seq=1
        for offset in range(0,len(gray),1024):
            self.client.transact(Packet(0x11,transfer_id,seq,gray[offset:offset+1024]),0)
            seq+=1
            if progress: progress(min(offset+1024,len(gray)),len(gray))
        if stage: stage('FPGA 正在计算 HOG 特征与 SVM 得分…')
        start=time.monotonic()
        payload=self.client.transact(Packet(0x12,transfer_id,seq),2,timeout=5).payload
        self.calculation_seconds=time.monotonic()-start
        if struct.unpack('<H',payload)[0]!=SCORE_COUNT: raise ProtocolError('incorrect HOG score count')
        seq+=1
        if stage: stage('正在读取 FPGA 的 495 个窗口得分…')
        scores=[]
        for offset in range(0,SCORE_COUNT,256):
            count=min(256,SCORE_COUNT-offset)
            reply=self.client.transact(Packet(0x13,transfer_id,seq,struct.pack('<HH',offset,count)),count*4)
            scores.extend(struct.unpack(f'<{count}i',reply.payload))
            seq+=1
        return scores


def gui_selftest(report_path,port,input_path):
    """Frozen acceptance: exercise the actual GUI worker against the physical board."""
    import json
    import sys
    import tkinter as tk
    from pathlib import Path
    from uart_image_gui import ImageApp
    import uart_image_gui
    report_path=Path(report_path)
    report={'status':'running','frozen':bool(getattr(sys,'frozen',False))}
    root=tk.Tk()
    root.attributes('-alpha',0.0)
    app=ImageApp(root)
    errors=[]
    uart_image_gui.messagebox.showerror=lambda title,message:errors.append(str(message))
    try:
        app.load_image(input_path)
        app.port.set(port)
        app.mode.set(HOG_LABEL)
        app.send()
        deadline=time.monotonic()+45
        while app.busy and time.monotonic()<deadline:
            root.update()
            time.sleep(0.01)
        assert not app.busy and not errors and app.result is not None,(app.busy,errors)
        gray,geometry=prepare_hog(app.source)
        expected,boxes=draw_detections(app.source,detect_reference(gray),geometry)
        assert app.result.tobytes()==expected.tobytes()
        output=report_path.with_suffix('.png')
        app.result.save(output)
        report.update(status='passed',result=str(output),boxes=boxes,gui_status=app.status.get(),model_id=f'{MODEL_ID:08X}')
    except Exception as exc:
        report.update(status='failed',error=repr(exc),gui_errors=errors)
    finally:
        root.destroy()
        report_path.parent.mkdir(parents=True,exist_ok=True)
        report_path.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    return 0 if report['status']=='passed' else 1
