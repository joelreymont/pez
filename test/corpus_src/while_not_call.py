def while_not_call(ev):
    out = []
    while not ev.wait(0):
        out.append(1)
    return out

