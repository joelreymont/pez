cache = {}
hooks = []


def get_importer(path_item):
    try:
        importer = cache[path_item]
    except KeyError:
        for hook in hooks:
            try:
                importer = hook(path_item)
                cache.setdefault(path_item, importer)
                break
            except ImportError:
                pass
        else:
            importer = None
    return importer
