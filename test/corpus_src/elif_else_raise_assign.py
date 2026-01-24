def f(family):
    if family == 4:
        host = 'v4'
    elif family == 6:
        host = 'v6'
    else:
        raise ValueError('bad')
    return host
