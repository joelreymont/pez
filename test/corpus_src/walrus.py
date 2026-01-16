# Walrus operator (PEP 572)
if (n := len([1, 2, 3])) > 2:
    print(n)

while (line := input()) != "quit":
    print(line)

data = [1, 2, 3, 4, 5]
filtered = [y for x in data if (y := x * 2) > 4]
