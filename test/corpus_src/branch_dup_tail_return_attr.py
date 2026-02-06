def read_code(f):
    return f.read()


class Loader:
    code = None

    def __init__(self, file, kind):
        self.file = file
        self.kind = kind

    def _reopen(self):
        pass

    def get(self):
        if self.code is None:
            if self.kind == 1:
                self._reopen()
                try:
                    self.code = read_code(self.file)
                finally:
                    self.file.close()
                return self.code
        return self.code
