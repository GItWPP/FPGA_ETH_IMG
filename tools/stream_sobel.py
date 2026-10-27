"""Border packing and GRAY8 display only; all Sobel arithmetic runs in FPGA."""
from dataclasses import dataclass
import numpy as np
from PIL import Image
from rgb565_codec import encode_rgb565


@dataclass(frozen=True)
class PreparedSobelFrame:
    source: Image.Image
    padded: bytes


def pad_rgb565(raw,width,height):
    if len(raw) != width*height*2 or width < 1 or height < 1:
        raise ValueError('Invalid RGB565 frame')
    pixels=np.frombuffer(raw,dtype='<u2').reshape(height,width)
    return np.pad(pixels,((0,1),(0,1)),mode='edge').tobytes()


def prepare_sobel_frame(image):
    return PreparedSobelFrame(image,pad_rgb565(encode_rgb565(image),*image.size))


def output_prefix(pixels,width):
    rows,columns=divmod(pixels,width+1)
    return max(0,rows-1)*width + (max(0,columns-1) if rows else 0)


def iter_stream_chunks(padded,width,height):
    if len(padded) != (width+1)*(height+1)*2:
        raise ValueError('Invalid padded stream length')
    for pos in range(0,len(padded),1024):
        payload=padded[pos:pos+1024]
        end=pos+len(payload)
        count=output_prefix(end//2,width)-output_prefix(pos//2,width)
        yield payload,count


def decode_gray8(data,width,height):
    if len(data) != width*height:
        raise ValueError('GRAY8字节数与图像尺寸不一致')
    return Image.frombytes('L',(width,height),data).convert('RGB')
