import os


def f(importer, filenames, prefix=''):
    yielded = {}
    import inspect
    for fn in filenames:
        modname = inspect.getmodulename(fn)
        if modname == '__init__' or modname in yielded:
            continue
        path = os.path.join(importer.path, fn)
        ispkg = False
        if not modname and os.path.isdir(path) and '.' not in fn:
            modname = fn
            try:
                dircontents = os.listdir(path)
            except OSError:
                dircontents = []
            for fn in dircontents:
                subname = inspect.getmodulename(fn)
                if subname == '__init__':
                    ispkg = True
                    break
            else:
                continue
        if modname and '.' not in modname:
            yielded[modname] = 1
            yield prefix + modname, ispkg
