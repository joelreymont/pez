# Comprehensions
nums = [1, 2, 3, 4, 5]

# List comprehension
squares = [x**2 for x in nums]
evens = [x for x in nums if x % 2 == 0]
nested = [[x, y] for x in nums for y in nums if x != y]

# Dict comprehension
d = {x: x**2 for x in nums}

# Set comprehension
s = {x for x in nums if x > 2}

# Generator expression
g = (x**2 for x in nums)
