def read(fp, decomp, trailing_error):
    data = None
    while True:
        rawblock = fp.read(4)
        if not rawblock:
            break
        try:
            data = decomp.decompress(rawblock, 1)
        except trailing_error:
            break
        if data:
            break
    return data
