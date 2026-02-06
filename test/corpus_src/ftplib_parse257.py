class error_reply(Exception):
    pass


def parse257(resp):
    if resp[:3] != "257":
        raise error_reply(resp)
    if resp[3:5] != ' "':
        return ""
    dirname = ""
    i = 5
    n = len(resp)
    while i < n:
        c = resp[i]
        i = i + 1
        if c == '"':
            if i >= n or resp[i] != '"':
                break
            i = i + 1
        dirname = dirname + c
    return dirname
