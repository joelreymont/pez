import time


def f(flag, sock):
    while True:
        if flag():
            time.sleep(30)
            continue
        try:
            sock.recv(1)
        except Exception:
            return
