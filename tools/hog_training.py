"""Vectorized, bit-exact integer HOG helpers for offline training only."""
from __future__ import annotations
import numpy as np
from PIL import Image


def feature_map(gray):
    gray=np.asarray(gray,dtype=np.int16)
    height,width=gray.shape
    if height%8 or width%8: raise ValueError('frame dimensions must be multiples of eight')
    padded=np.pad(gray,1,mode='edge')
    gx=padded[1:-1,2:]-padded[1:-1,:-2]
    gy=padded[2:,1:-1]-padded[:-2,1:-1]
    ax,ay=np.abs(gx).astype(np.int32),np.abs(gy).astype(np.int32)
    q=ay*256
    bins=np.select([q<ax*93,q<ax*215,q<ax*443,q<ax*1452],[0,1,2,3],4)
    bins=np.where((gx<0)!=(gy<0),8-bins,bins)
    bins=np.where(ay==0,0,bins)
    yy,xx=np.indices(gray.shape)
    index=((yy//8)*(width//8)+xx//8)*9+bins
    hist=np.bincount(index.ravel(),weights=(ax+ay).ravel(),minlength=height//8*(width//8)*9)
    hist=hist.astype(np.int32).reshape(height//8,width//8,9)
    blocks=np.concatenate([hist[:-1,:-1],hist[:-1,1:],hist[1:,:-1],hist[1:,1:]],axis=2)
    result=(blocks*1024//(blocks.sum(axis=2,keepdims=True)+1)).astype(np.uint16)
    return result


def all_windows(blocks):
    """Return 3780-feature windows ordered by window y/x; views avoid repeated gradient work."""
    rows,columns,_=blocks.shape
    if rows<15 or columns<7: raise ValueError('image too small for a 64x128 detector')
    windows=np.lib.stride_tricks.sliding_window_view(blocks,(15,7),axis=(0,1))
    return windows.transpose(0,1,3,4,2).reshape((rows-14)*(columns-6),3780).copy()


def descriptor(gray,x,y):
    # A one-pixel halo reproduces gradients from the full source, including physical boundaries.
    a=np.asarray(gray,dtype=np.uint8)
    if x<0 or y<0 or x+64>a.shape[1] or y+128>a.shape[0]: raise ValueError('window outside image')
    padded=np.pad(a,1,mode='edge')
    context=padded[y:y+130,x:x+66].astype(np.int16)
    gx=context[1:-1,2:]-context[1:-1,:-2]
    gy=context[2:,1:-1]-context[:-2,1:-1]
    ax,ay=np.abs(gx).astype(np.int32),np.abs(gy).astype(np.int32)
    q=ay*256
    bins=np.select([q<ax*93,q<ax*215,q<ax*443,q<ax*1452],[0,1,2,3],4)
    bins=np.where((gx<0)!=(gy<0),8-bins,bins)
    bins=np.where(ay==0,0,bins)
    yy,xx=np.indices((128,64))
    index=((yy//8)*8+xx//8)*9+bins
    hist=np.bincount(index.ravel(),weights=(ax+ay).ravel(),minlength=16*8*9).astype(np.int32).reshape(16,8,9)
    blocks=np.concatenate([hist[:-1,:-1],hist[:-1,1:],hist[1:,:-1],hist[1:,1:]],axis=2)
    return (blocks*1024//(blocks.sum(axis=2,keepdims=True)+1)).astype(np.uint16).ravel()


def gray_array(path):
    with Image.open(path) as image:
        return np.array(image.convert('L'))


def integer_scores(rows,weights,bias):
    scores=rows.astype(np.int64)@np.asarray(weights,dtype=np.int64)+int(bias)
    return np.clip(scores,-(1<<31),(1<<31)-1)


def select_spaced(scores,columns,excluded=(),limit=16,minimum=-0.2,overlap=0.4):
    """Hard windows from training backgrounds only; spatially suppress near duplicates."""
    excluded=set(excluded)
    selected=[]
    for index in np.argsort(-scores):
        index=int(index)
        if scores[index]<=minimum: break
        if index in excluded: continue
        x,y=index%columns*8,index//columns*8
        keep=True
        for other in selected:
            ox,oy=other%columns*8,other//columns*8
            intersection=max(0,64-abs(x-ox))*max(0,128-abs(y-oy))
            if intersection/(16384-intersection)>overlap:
                keep=False
                break
        if keep: selected.append(index)
        if len(selected)>=limit: break
    return selected
