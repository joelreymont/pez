def g():
    pass


def f(flag, other):
    if flag:
        x = 1
    elif other:
        try:
            g()
        except ValueError:
            return None
        x = 2
    return x
