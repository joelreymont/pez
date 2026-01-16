# PEP 695: Type Parameter Syntax (Python 3.12+)

def func[T](x: T) -> T:
    return x

def func_with_bound[T: int](x: T) -> T:
    return x

def func_with_constraint[T: (int, str)](x: T) -> T:
    return x

class Stack[T]:
    def __init__(self):
        self.items: list[T] = []

    def push(self, item: T) -> None:
        self.items.append(item)

    def pop(self) -> T:
        return self.items.pop()

class Box[T, U]:
    def __init__(self, first: T, second: U):
        self.first = first
        self.second = second

type Point = tuple[float, float]
type Vec[T] = list[T]
type Nested[T] = list[list[T]]
