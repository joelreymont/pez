# Match statement (PEP 634)
def match_literal(x):
    match x:
        case 1:
            return "one"
        case 2:
            return "two"
        case _:
            return "other"

def match_sequence(x):
    match x:
        case []:
            return "empty"
        case [a]:
            return f"single: {a}"
        case [a, b]:
            return f"pair: {a}, {b}"
        case [a, *rest]:
            return f "first: {a}, rest: {rest}"

def match_mapping(x):
    match x:
        case {}:
            return "empty"
        case {"key": value}:
            return f"key: {value}"
        case {"a": a, "b": b}:
            return f"a={a}, b={b}"
