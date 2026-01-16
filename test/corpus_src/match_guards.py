# Match guards (PEP 634)

def guard_simple(x):
    match x:
        case n if n < 0:
            return "neg"
        case n if n == 0:
            return "zero"
        case n if n > 0:
            return "pos"
        case _:
            return "other"

def guard_sequence(x):
    match x:
        case [a, b] if a < b:
            return "asc"
        case [a, b] if a > b:
            return "desc"
        case [a, b] if a == b:
            return "eq"
        case _:
            return "nope"

def guard_mapping(x):
    match x:
        case {"val": v} if v > 0:
            return "positive"
        case {"val": v} if v < 0:
            return "negative"
        case {"val": 0}:
            return "zero"
        case _:
            return "unknown"

class Point:
    def __init__(self, x, y):
        self.x = x
        self.y = y

def guard_class(p):
    match p:
        case Point(x=x, y=y) if x == y:
            return "diag"
        case Point(x=x, y=y) if x < y:
            return "up"
        case Point(x=x, y=y) if x > y:
            return "down"
        case _:
            return "other"

def guard_or(x):
    match x:
        case 1 | 3 | 5 if x % 2 == 1:
            return "odd"
        case 2 | 4 | 6 if x % 2 == 0:
            return "even"
        case _:
            return "other"

def guard_as(x):
    match x:
        case [a, b] as seq if len(seq) == 2 and a != b:
            return seq
        case (a, (b, c)) if a < b < c:
            return (a, b, c)
        case _:
            return None
