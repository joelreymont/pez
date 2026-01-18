def f(a, b):
    try:
        if a == 1 or b == 2:
            raise Exception("bad")
        x = a + b
        return x
    except Exception as e:
        print(e)
