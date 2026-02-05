def or_break_guard(timeout, val, buf):
    i = 0
    while i < 1:
        i += 1
        if timeout.expired() or val is not None and val > 0 and not buf:
            break
    return None
