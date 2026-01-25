def f(x):
    a = get_a(x)
    if a:
        do_something(a)
    else:
        a = get_b(x)
        if not a.startswith('<') or not a.endswith('>'):
            raise ValueError('bad')
    # This should be reached from both branches
    return process(a)
