def f(rows):
    out = []
    for row in rows:
        cw = 10
        names = (cw + i for i in row)
        out.append(list(names))
        for j in range(3):
            out.append(cw + j)
    return out

