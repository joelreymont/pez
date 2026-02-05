def guard_in_return(item, seq):
    if item in seq:
        return item
    raise KeyError(item)
