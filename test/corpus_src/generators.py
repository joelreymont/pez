# Generators
def simple_gen():
    yield 1
    yield 2
    yield 3

def gen_with_return():
    yield 1
    return 42

def gen_with_send():
    x = yield 1
    y = yield x + 1
    return y

def gen_yield_from():
    yield from range(5)
