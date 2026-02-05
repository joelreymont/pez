class Breakpoint:
    bplist = {}


def canonic(x):
    return x


def and_chain_or(breaks, filename, lineno):
    filename = canonic(filename)
    return filename in breaks and lineno in breaks[filename] and Breakpoint.bplist[filename, lineno] or []

