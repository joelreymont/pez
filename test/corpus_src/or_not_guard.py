def f(a, b):
    if not a.check() or not b.check():
        return 'fail'
    return 'ok'
