def f(protocol):
    if protocol == 4:
        return "v4"
    elif protocol == 6:
        return "v6"
    raise ValueError("unknown protocol")
