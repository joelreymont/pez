# Python 2.x specific features

# Print statement (not function)
print "hello world"
print "x =", 42

# Exec statement
exec "x = 5"

# Integer division
x = 10 / 3  # returns 3 in Python 2

# String types
u = u"unicode string"
b = b"byte string"

# Old-style class
class OldStyle:
    pass

# New-style class
class NewStyle(object):
    pass

# Long integer literal
big = 999999999999999999999L

# Octal literal (old syntax)
octal = 0777

# Backticks for repr
x = 42
s = `x`  # equivalent to repr(x)

# <> operator
if 5 <> 3:
    pass

# raise statement (old syntax)
raise ValueError, "message"
raise ValueError, "message", None

# except clause (old syntax)
try:
    pass
except ValueError, e:
    pass

# Function with tuple parameter unpacking
def func((a, b)):
    return a + b
