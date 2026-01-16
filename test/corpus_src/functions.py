# Functions
def simple():
    return 42

def with_args(a, b, c):
    return a + b + c

def with_defaults(a, b=10, c=20):
    return a + b + c

def with_varargs(*args):
    return sum(args)

def with_kwargs(**kwargs):
    return len(kwargs)

def with_all(a, b=1, *args, **kwargs):
    return a + b + len(args) + len(kwargs)

# Lambdas
f = lambda x: x * 2
g = lambda x, y: x + y
