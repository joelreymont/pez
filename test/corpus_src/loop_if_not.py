def f(items):
    out = []
    for x in items:
        if not is_valid(x):
            out.append(x)
        else:
            out.append(x + 1)
    return out
