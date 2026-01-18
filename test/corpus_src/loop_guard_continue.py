def f(entries):
    for entry in entries:
        if not entry:
            continue
        if entry.endswith('.egg'):
            entries.append(entry)
