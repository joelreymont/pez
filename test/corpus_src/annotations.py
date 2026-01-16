# Type annotations
x: int
y: int = 10
z: str = "hello"

def func(a: int, b: str) -> bool:
    return len(b) > a

class Typed:
    x: int
    y: str

    def method(self, a: int) -> int:
        return a * 2
