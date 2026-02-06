import os


def _iterdir(dirname, dironly):
    if not dirname:
        if isinstance(dirname, bytes):
            dirname = bytes(os.curdir, "ASCII")
        else:
            dirname = os.curdir
    try:
        with os.scandir(dirname) as it:
            for entry in it:
                try:
                    if not dironly or entry.is_dir():
                        yield entry.name
                except OSError:
                    pass
    except OSError:
        return None
