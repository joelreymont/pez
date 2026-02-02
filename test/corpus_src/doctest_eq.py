class Example:
    def __init__(self, source, want, lineno, indent, options, exc_msg):
        self.source = source
        self.want = want
        self.lineno = lineno
        self.indent = indent
        self.options = options
        self.exc_msg = exc_msg

    def __eq__(self, other):
        if type(self) is not type(other):
            return NotImplemented
        elif self.source == other.source and self.want == other.want:
            return self.lineno == other.lineno and self.indent == other.indent and self.options == other.options and self.exc_msg == other.exc_msg
        return False
