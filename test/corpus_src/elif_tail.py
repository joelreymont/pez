import io
import socket
from pathlib import Path


def elif_tail(obj, file):
    obj._split = False
    obj._needs_close = False
    if file is None:
        obj._fileoutput = None
    else:
        if isinstance(file, str) or isinstance(file, Path):
            obj._fileoutput = open(file, "wb")
            obj._needs_close = True
        elif isinstance(file, io.BufferedIOBase):
            obj._fileoutput = file
        else:
            raise RuntimeError("bad")
        if hasattr(obj._fileoutput, "raw") and isinstance(obj._fileoutput.raw, socket.SocketIO):
            if obj._fileoutput.raw._sock.type == socket.SocketKind.SOCK_DGRAM:
                obj._split = True

