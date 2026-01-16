# Context managers
class CM:
    def __enter__(self):
        return self
    def __exit__(self, *args):
        pass

with CM() as c:
    x = 1

with CM():
    y = 2

with CM() as a, CM() as b:
    z = 3
