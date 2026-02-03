def make():
    return object()


def build(session):
    return (lambda: session if session else make())()
