def iglob_like(pathname, recursive=False):
    it = iter((0,))
    if recursive and pathname:
        s = next(it)
        assert not s
    return it


def _ishidden(path):
    return path[0] == "."


def rlistdir_like(names):
    for x in names:
        if _ishidden(x):
            continue
        yield x
        path = x
        for y in rlistdir_like(path):
            yield y
