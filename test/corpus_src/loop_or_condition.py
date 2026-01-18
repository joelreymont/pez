def f(mods, package):
    for mod in mods:
        if mod == package or mod.startswith(f'{package}.'):
            mods.append(mod)
