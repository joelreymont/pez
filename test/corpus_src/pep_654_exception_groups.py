# PEP 654: Exception Groups (Python 3.11+)

def test_except_star():
    try:
        raise ExceptionGroup("group", [ValueError("v"), TypeError("t")])
    except* ValueError as e:
        print(f"caught ValueError: {e}")
    except* TypeError as e:
        print(f"caught TypeError: {e}")

def test_nested_exception_groups():
    try:
        raise ExceptionGroup(
            "outer",
            [
                ValueError("v1"),
                ExceptionGroup("inner", [TypeError("t1"), KeyError("k1")]),
            ],
        )
    except* ValueError as e:
        print(f"caught ValueError: {e}")
    except* TypeError as e:
        print(f"caught TypeError: {e}")

def test_reraise_exception_group():
    try:
        raise ExceptionGroup("group", [ValueError("v"), TypeError("t")])
    except* ValueError:
        print("handling ValueError")
        raise
