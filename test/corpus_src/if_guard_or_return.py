import os


def f(importer):
    if importer.path is None or not os.path.isdir(importer.path):
        return None
    return 1
