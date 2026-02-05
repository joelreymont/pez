def if_ret_raise_and(a, x):
    i = 0
    if i != len(a) and a[i] == x:
        return i
    raise ValueError

