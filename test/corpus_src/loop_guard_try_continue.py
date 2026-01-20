import time


def f(sock):
    while True:
        try:
            data = sock.recv(1024)
            if not data:
                continue
            sock.send(data)
        except Exception as e:
            print(e)
            time.sleep(1)
