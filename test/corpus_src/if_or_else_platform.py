import platform

if platform.system() == "Darwin" or "BSD" in platform.system():
    x = 1
else:
    x = 2

