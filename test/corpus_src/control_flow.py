# Control flow
x = 5
if x == 5:
    y = 1
elif x == 4:
    y = 2
else:
    y = 3

for i in range(10):
    if i == 5:
        break
    if i == 3:
        continue
    print(i)

while x > 0:
    x -= 1
    if x == 2:
        break
