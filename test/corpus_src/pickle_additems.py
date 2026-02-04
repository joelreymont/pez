def load_additems(items, set_obj):
    if isinstance(set_obj, set):
        set_obj.update(items)
    else:
        add = set_obj.add
        for item in items:
            add(item)
