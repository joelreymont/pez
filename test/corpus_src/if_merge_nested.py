def merge_if_nested(x):
    if isinstance(x, float):
        if x > 0:
            x = int(x)
        else:
            x = int(-x)
    else:
        x = x
    return x
