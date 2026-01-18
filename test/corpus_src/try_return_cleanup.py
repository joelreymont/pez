def pick(items):
    for item in items:
        try:
            return item
        except Exception:
            pass
