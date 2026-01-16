# PEP 701: Syntactic formalization of f-strings (Python 3.12+)

def test_nested_fstrings():
    x = 5
    y = 10
    return f"{f'{x} + {y} = {x + y}'}"

def test_fstring_with_quotes():
    name = "Alice"
    return f"Name: {f'{name.upper()}'}"

def test_fstring_with_backslashes():
    # Previously forbidden, now allowed
    x = [1, 2, 3]
    return f"{'\n'.join(str(i) for i in x)}"

def test_fstring_multiline():
    x = 42
    return f"""
    Value: {x}
    Squared: {x ** 2}
    """

def test_fstring_with_expressions():
    x = 10
    return f"{x if x > 5 else 0}"

def test_fstring_debugging():
    x = 42
    return f"{x=}"

def test_fstring_format_spec():
    pi = 3.14159
    return f"{pi:.2f}"
