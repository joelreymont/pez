# Exceptions
try:
    x = 1 / 0
except ZeroDivisionError:
    x = 0

try:
    y = int("not a number")
except ValueError as e:
    y = 0

try:
    z = 1 / 0
except ZeroDivisionError:
    z = 0
else:
    z = 1
finally:
    z = 2

try:
    a = 1
except (ValueError, TypeError):
    a = 2

try:
    b = 1
except Exception:
    b = 2
    raise
