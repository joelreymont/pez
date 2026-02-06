import sys

def parse_lines(lines, inline_prefixes):
    out = []
    for line in lines:
        comment_start = sys.maxsize
        inline = {p: -1 for p in inline_prefixes}
        while comment_start == sys.maxsize and inline:
            nxt = {}
            for prefix, index in inline.items():
                index = line.find(prefix, index + 1)
                if index == -1:
                    continue
                nxt[prefix] = index
                if index == 0 or index > 0 and line[index - 1].isspace():
                    comment_start = min(comment_start, index)
            inline = nxt
        if comment_start == sys.maxsize:
            comment_start = None
        value = line[:comment_start].strip()
        if not value:
            continue
        out.append(value)
    return out
