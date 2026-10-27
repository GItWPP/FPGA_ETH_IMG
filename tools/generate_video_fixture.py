"""Create a small moving MP4 from the project's canonical test pictures."""
import argparse
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
from PIL import Image,ImageOps
from project_paths import ROOT,user_test_image


def generate(output, *, seconds=6, fps=30, size=(640,360)):
    if seconds <= 0 or not 1 <= fps <= 120:
        raise ValueError('Invalid fixture duration or frame rate')
    output = Path(output)
    output.parent.mkdir(parents=True,exist_ok=True)
    names = ('hog_validation_scene.png','test1.png','Ai-marketing.jpg')
    images = []
    for name in names:
        with Image.open(user_test_image(name)) as image:
            images.append(np.asarray(ImageOps.fit(image.convert('RGB'),size)))
    writer = cv2.VideoWriter(str(output),cv2.VideoWriter_fourcc(*'mp4v'),fps,size)
    if not writer.isOpened():
        raise RuntimeError('Cannot create the MP4 fixture using the packaged FFmpeg encoder')
    count = round(seconds*fps)
    try:
        for index in range(count):
            base = images[min(len(images)-1,index*len(images)//count)]
            rgb = np.roll(base,index%17-8,axis=1)
            bgr = cv2.cvtColor(rgb,cv2.COLOR_RGB2BGR)
            cv2.rectangle(bgr,(0,0),(280,25),(15,15,15),-1)
            cv2.putText(bgr,f'FPGA frame {index:04d}  {index/fps:.2f}s',(8,18),cv2.FONT_HERSHEY_SIMPLEX,0.5,(40,240,80),1,cv2.LINE_AA)
            writer.write(bgr)
    finally:
        writer.release()
    report = dict(file=output.name,width=size[0],height=size[1],fps=fps,frames=count,
                  source_images=list(names),sha256=hashlib.sha256(output.read_bytes()).hexdigest())
    output.with_suffix('.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'test_video/fpga_demo.mp4')
    parser.add_argument('--seconds',type=float,default=6)
    parser.add_argument('--fps',type=int,default=30)
    args = parser.parse_args()
    print(json.dumps(generate(args.output,seconds=args.seconds,fps=args.fps),indent=2))


if __name__ == '__main__':
    main()
