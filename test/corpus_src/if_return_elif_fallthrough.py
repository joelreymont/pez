def f(returncode, timeout):
    if returncode is not None:
        return returncode
    elif timeout is not None:
        a = 1
    else:
        b = 2
    return returncode
