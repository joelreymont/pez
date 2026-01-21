def f(limit, _read):
    if limit is not None and 0 <= limit <= _read:
        return True
    return False
