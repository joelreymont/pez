# PEP 709: Inlined Comprehensions (Python 3.12+)
# Comprehensions are now inlined instead of using separate code objects

def test_list_comp():
    return [x * 2 for x in range(10)]

def test_nested_list_comp():
    return [[x * y for x in range(3)] for y in range(3)]

def test_dict_comp():
    return {x: x ** 2 for x in range(10)}

def test_set_comp():
    return {x % 3 for x in range(10)}

def test_generator_exp():
    return (x * 2 for x in range(10))

def test_comp_with_if():
    return [x for x in range(20) if x % 2 == 0]

def test_comp_with_walrus():
    return [y for x in range(10) if (y := x * 2) > 10]

def test_nested_comp_with_walrus():
    return [(i, j) for i in range(5) if (j := i * 2) < 8]
