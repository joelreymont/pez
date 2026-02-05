def loop_merge_break(xs):
    for x in xs:
        if x:
            y = 1
        else:
            y = 2
        break
    else:
        raise ValueError("empty")
    return y

