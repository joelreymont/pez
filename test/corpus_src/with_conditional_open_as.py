_DEFAULT = object()

def open_binary(fname):
    return fname

def open_text(fname):
    return fname

def cat(fname, fallback=_DEFAULT, binary=True):
    try:
        with (open_binary(fname) if binary else open_text(fname)) as f:
            return f.read().strip()
    except (IOError, OSError):
        if fallback is not _DEFAULT:
            return fallback
        raise
