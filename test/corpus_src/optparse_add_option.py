class Option:
    pass


class Container:
    option_class = Option

    def add_option(self, *args, **kwargs):
        if isinstance(args[0], str):
            option = self.option_class(*args, **kwargs)
        elif len(args) == 1 and not kwargs:
            option = args[0]
            if not isinstance(option, Option):
                raise TypeError('%r' % option)
        else:
            raise TypeError('invalid arguments')
        return option

