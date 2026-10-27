"""Exact little-endian RGB565 conversion shared by image and video clients."""
import numpy as np
from PIL import Image


def encode_rgb565(image):
    rgb = np.asarray(image.convert('RGB'),dtype=np.uint16)
    pixels = ((rgb[:,:,0] >> 3) << 11) | ((rgb[:,:,1] >> 2) << 5) | (rgb[:,:,2] >> 3)
    return pixels.astype('<u2',copy=False).tobytes()


def decode_rgb565(data, width, height):
    if width < 1 or height < 1 or len(data) != width*height*2:
        raise ValueError('RGB565字节数与图像尺寸不一致')
    pixels = np.frombuffer(data,dtype='<u2').reshape(height,width)
    red,green,blue = pixels >> 11,(pixels >> 5) & 63,pixels & 31
    rgb = np.stack(((red << 3) | (red >> 2), (green << 2) | (green >> 4),
                    (blue << 3) | (blue >> 2)),axis=2).astype(np.uint8)
    return Image.fromarray(rgb)
