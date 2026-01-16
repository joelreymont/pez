# Classes
class Simple:
    pass

class WithInit:
    def __init__(self, x):
        self.x = x

class WithMethods:
    def __init__(self, x):
        self.x = x

    def method(self):
        return self.x * 2

    @classmethod
    def cls_method(cls):
        return cls

    @staticmethod
    def static_method():
        return 42

class Derived(WithInit):
    def __init__(self, x, y):
        super().__init__(x)
        self.y = y
