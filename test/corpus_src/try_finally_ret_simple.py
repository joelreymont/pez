def side_effect() -> None:
    pass


def try_finally_ret_simple(x):
    try:
        return x + 1
    finally:
        side_effect()

