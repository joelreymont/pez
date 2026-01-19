def f(data):
    out = []
    i = 0
    while True:
        if data[i] == 0:
            out.append(i)
            return out
        out.append(data[i])
        i += 1
