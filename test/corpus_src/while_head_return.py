def while_head_return(fields, sparse, buf, read, tell):
    while True:
        if len(sparse) >= fields * 2:
            pos = tell()
            return pos, list(zip(sparse[::2], sparse[1::2]))
        if b"\n" not in buf:
            buf += read()
        n, buf = buf.split(b"\n", 1)
        sparse.append(int(n))
