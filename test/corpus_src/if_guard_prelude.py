
def if_guard_prelude(obj):
    if not obj:
        if obj is None:
            return None
        return 0
    n = len(obj)
    if n <= 3:
        return n
    return n + 1
