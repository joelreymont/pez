def nested_search(path):
    for entry in path:
        for suffix, mode in ((".py", "r"), (".pyc", "rb")):
            file_path = entry + suffix
            if file_path.endswith(".pyc"):
                break
    else:
        raise RuntimeError("not found")
    return (file_path, suffix, mode)
