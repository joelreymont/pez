def listcomp_ifexp(xs):
    return [x.decode('latin1') if x is not None else x for x in xs]
