def guard_loop(it):
    lines = []
    while True:
        while len(lines) < 4:
            lines.append(next(it, "X"))
        s = ''.join([line[0] for line in lines])
        if s.startswith("X"):
            return None
        yield s
