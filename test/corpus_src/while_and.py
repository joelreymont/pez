def f(stack, n):
    while stack and n > 0:
        item = stack.pop()
        n -= 1
    return n
