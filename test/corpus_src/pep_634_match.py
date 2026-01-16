# PEP 634: Structural Pattern Matching (Python 3.10+)

def test_match_literal():
    x = 5
    match x:
        case 1:
            return "one"
        case 5:
            return "five"
        case _:
            return "other"

def test_match_sequence():
    point = (1, 2)
    match point:
        case (0, 0):
            return "origin"
        case (x, 0):
            return f"x-axis at {x}"
        case (0, y):
            return f"y-axis at {y}"
        case (x, y):
            return f"point at ({x}, {y})"

def test_match_mapping():
    data = {"name": "Alice", "age": 30}
    match data:
        case {"name": name, "age": age}:
            return f"{name} is {age}"
        case _:
            return "unknown"

def test_match_class():
    class Point:
        def __init__(self, x, y):
            self.x = x
            self.y = y

    p = Point(1, 2)
    match p:
        case Point(x=0, y=0):
            return "origin"
        case Point(x=x, y=y):
            return f"point at ({x}, {y})"

def test_match_guard():
    x = 10
    match x:
        case n if n < 0:
            return "negative"
        case n if n == 0:
            return "zero"
        case n if n > 0:
            return "positive"

def test_match_or():
    x = 5
    match x:
        case 1 | 2 | 3:
            return "small"
        case 4 | 5 | 6:
            return "medium"
        case _:
            return "large"

def test_match_as():
    point = (1, 2)
    match point:
        case (x, y) as p:
            return f"matched {p}"

def test_match_star():
    values = [1, 2, 3, 4, 5]
    match values:
        case [first, *rest]:
            return f"first={first}, rest={rest}"
        case _:
            return "empty"
