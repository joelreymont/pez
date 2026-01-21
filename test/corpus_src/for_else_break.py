def find_pkg(pkgs):
    for pkg in pkgs:
        try:
            if pkg == 'ok':
                break
        except ImportError:
            pass
    else:
        raise ValueError('no pkg')
    return pkg
