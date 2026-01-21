logfp = None


def dolog(*args):
    pass


def nolog(*args):
    pass


def initlog(*args):
    global logfp, log
    if logfp:
        log = dolog
    else:
        log = nolog
    log(*args)
