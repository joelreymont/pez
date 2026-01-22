class _Base:
    pass

class Generic:
    pass


def f(bases, i):
    for b in bases[i + 1:]:
        if not isinstance(b, _Base):
            if issubclass(b, Generic):
                break
        else:
            break
