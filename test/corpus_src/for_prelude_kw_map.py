def g(x, **kw):
    return True

def f(iterable, flag=None):
    kw = {'k': flag if flag is not None else True}
    for item in iterable:
        if g(*(item,), **kw):
            yield item
