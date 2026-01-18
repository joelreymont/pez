class Reader:
    def __init__(self, fp):
        self.fp = fp

    def read(self):
        text = ''
        while True:
            data = self.fp.readline()
            text = text + data
            if not data.strip():
                break
        return text
