def loop_while_in_for(items):
    out = []
    for name, values in items.items():
        while values:
            out.append(values.pop(0))
    return out
