def try_except_raise(do):
    try:
        do()
    except Exception:
        print('err')
        raise
