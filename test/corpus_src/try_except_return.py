def f():
    try:
        x()
    except Exception:
        y()
    return None
