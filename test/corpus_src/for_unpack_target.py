def build(items, prefix):
    out = []
    for entry_name, entry_data in items:
        name_component = entry_name[len(prefix):]
        out.append((name_component, entry_data))
    for head, *rest in items:
        out.append((head, rest))
    return out
