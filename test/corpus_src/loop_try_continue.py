import time

def loop_try(msg):
    for i in range(0, 5):
        try:
            print(msg)
            break
        except:
            time.sleep(1)

def tail_if(x):
    if x == 1:
        return None
    elif x == 2:
        return None
    else:
        try:
            foo()
        except Exception as e:
            bar()
