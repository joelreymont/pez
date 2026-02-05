import types


def set_cb(obj, cb):
    if isinstance(cb, types.FunctionType) or cb is None:
        obj.cb = cb
    else:
        raise RuntimeError("cb must be None or function")

