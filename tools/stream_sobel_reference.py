"""Independent offline reference, used only by acceptance checks, never processing."""
import numpy as np


def reference_gray8(raw,width,height):
    pixels=np.frombuffer(raw,dtype='<u2').reshape(height,width).astype(np.int32)
    r,g,b=pixels>>11,(pixels>>5)&63,pixels&31
    gray=((77*((r<<3)|(r>>2))+150*((g<<2)|(g>>4))+29*((b<<3)|(b>>2)))>>8).astype(np.int16)
    p=np.pad(gray,1,mode='edge')
    gx=p[:-2,2:]+2*p[1:-1,2:]+p[2:,2:]-p[:-2,:-2]-2*p[1:-1,:-2]-p[2:,:-2]
    gy=p[2:,:-2]+2*p[2:,1:-1]+p[2:,2:]-p[:-2,:-2]-2*p[:-2,1:-1]-p[:-2,2:]
    return np.minimum(255,np.abs(gx)+np.abs(gy)).astype(np.uint8).tobytes()
