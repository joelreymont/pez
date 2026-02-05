def getopt_mini(args, longopts):
    """Minimal getopt-like loop shape for parity tests."""
    opts = []
    if type(longopts) == type(""):
        longopts = [longopts]
    else:
        longopts = list(longopts)

    while args and args[0].startswith("-") and args[0] != "-":
        if args[0].startswith("--"):
            opts, args = do_longs(opts, args, longopts)
        else:
            opts, args = do_shorts(opts, args, longopts)

    return (opts, args)

