import threading

_lock = threading.RLock()
_val = None


def get_val(x):
    global _val
    with _lock:
        if _val is None:
            _val = x
        return _val
