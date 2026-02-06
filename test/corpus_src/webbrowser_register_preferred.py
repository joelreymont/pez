_lock = object()
_browsers = {}
_tryorder = None
_os_preferred_browser = None


def register_standard_browsers():
    pass


def register(name, klass, instance=None, *, preferred=False):
    with _lock:
        if _tryorder is None:
            register_standard_browsers()
        _browsers[name.lower()] = [klass, instance]
        if preferred or (_os_preferred_browser and name in _os_preferred_browser):
            _tryorder.insert(0, name)
        else:
            _tryorder.append(name)
