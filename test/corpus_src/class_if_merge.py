nt = True
supports_symlinks = False

class C:
    if nt:
        if supports_symlinks:
            symlink = 1
        else:
            symlink = 2
    else:
        symlink = 3
    utime = 4
