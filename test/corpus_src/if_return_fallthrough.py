# if-return fallthrough regression

def f(x):
    if x:
        return 1
    return 2
