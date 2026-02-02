
def loop_exit_reaches_header(xs):
    changed = True
    while True:
        changed = False
        for x in xs:
            if x == 0:
                changed = True
        if changed:
            continue
        break
