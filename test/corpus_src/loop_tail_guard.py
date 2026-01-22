from typing import List

def scan(vals: List[int]) -> int:
    pos = 0
    while pos < len(vals):
        v = vals[pos]
        if v == 0:
            if v != vals[0]:
                raise ValueError("bad0")
        elif v == 1:
            if v != vals[1]:
                raise ValueError("bad1")
        pos += 1
    return pos
