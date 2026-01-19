class C:
    def __init__(self):
        self.items = []

    def add(self, value):
        self.items += [value]

def add_video(codecs, codec):
    codecs["video"] += [codec]
