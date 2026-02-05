def side_effect() -> None:
    pass


def try_finally_return(x):
    try:
        return x + 1
    finally:
        if x:
            side_effect()

