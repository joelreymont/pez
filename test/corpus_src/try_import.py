try:
    import zlib
except ImportError as err:
    zlib = None
    err = None
else:
    zlib = zlib
