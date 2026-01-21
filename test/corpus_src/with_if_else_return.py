import threading

_lock = threading.RLock()


def f(x):
    with _lock:
        if x:
            x = x + 1
        else:
            return None
    return x
