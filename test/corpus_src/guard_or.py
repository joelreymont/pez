def guard(a, b):
    if not (a or b):
        raise ValueError('x')
    return (a, b)
