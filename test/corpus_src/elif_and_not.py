class Option:
    pass


def option_class(*args, **kwargs):
    _ = args
    _ = kwargs
    return Option()


class C:
    option_class = option_class

    def add(self, *args, **kwargs):
        if isinstance(args[0], str):
            option = self.option_class(*args, **kwargs)
        elif len(args) == 1 and not kwargs:
            option = args[0]
            if not isinstance(option, Option):
                raise TypeError("not an Option instance: %r" % option)
        else:
            raise TypeError("invalid arguments")
        return option

