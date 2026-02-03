def try_except_raise_after(do):
    try:
        do()
    except Exception:
        raise RuntimeError('boom')
    print('ok')
