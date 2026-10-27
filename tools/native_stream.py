"""Optional Windows UDP DATA loop; ctypes releases the GIL for a complete window."""
import ctypes
from functools import lru_cache
from pathlib import Path
import sys


class Metrics(ctypes.Structure):
    _fields_=[(name,ctypes.c_uint32) for name in ('retries','bad','peak','error_seq','error_code','sent')]

CANCEL=ctypes.CFUNCTYPE(ctypes.c_int)


@lru_cache(maxsize=1)
def library():
    if sys.platform!='win32':return None
    path=Path(sys._MEIPASS)/'stream_udp.dll' if getattr(sys,'frozen',False) else Path(__file__).parent/'native/stream_udp.dll'
    if not path.exists():return None
    dll=ctypes.CDLL(str(path))
    call=dll.stream_sobel_exchange
    call.argtypes=[ctypes.c_size_t,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_uint32,
        ctypes.c_uint16,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,
        CANCEL,ctypes.POINTER(Metrics)]
    call.restype=ctypes.c_int
    return dll


def exchange(client,padded,width,height,tid,progress):
    dll=library()
    if dll is None:return None
    from eth_image import TransferCancelled
    from uart_image import ProtocolError,ERRORS
    output=ctypes.create_string_buffer(width*height)
    metrics=Metrics()
    cancel=CANCEL(lambda:int(client.cancel_event is not None and client.cancel_event.is_set()))
    old_timeout=client.socket.gettimeout()
    client.socket.setblocking(False)
    try:
        status=dll.stream_sobel_exchange(client.socket.fileno(),ctypes.c_char_p(padded),len(padded),width,height,
            tid,client.active_window,max(1,round(client.timeout*1000)),client.attempts,output,width*height,
            cancel,ctypes.byref(metrics))
    finally:client.socket.settimeout(old_timeout)
    client.retry_count+=metrics.retries
    client.bad_datagrams+=metrics.bad
    client.sent_datagrams+=metrics.sent
    client.window_peak=max(client.window_peak,metrics.peak)
    if status==-4:raise TransferCancelled('视频传输已停止')
    if status==-3:raise TimeoutError(f'流式UDP超时：序号{metrics.error_seq}')
    if status==-2:raise ProtocolError(f'FPGA error {metrics.error_code}: {ERRORS.get(metrics.error_code,"unspecified")}')
    if status==-1:raise OSError(metrics.error_code,'Windows UDP socket failure')
    if status:raise ProtocolError(f'流式UDP长度或内部状态错误：{status}')
    if progress:progress(width*height,width*height)
    return output.raw,(len(padded)+1023)//1024+1
