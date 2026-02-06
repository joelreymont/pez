def f(d):
    return {x: y.__dict__ if hasattr(y, '__dict__') else y for x, y in d.items()}


def g(new, old):
    out = {}
    for key in new:
        if key == 'user':
            continue
        if new[key] != old[key]:
            out[key] = [old[key], new[key]]
    return out
