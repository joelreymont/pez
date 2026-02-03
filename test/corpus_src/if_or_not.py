import logging


def warn(logger_level=logging.ERROR):
    if not logger_level or logger_level < logging.INFO:
        warning = "W"
    else:
        warning = ""
    return warning

