---
title: Create match guard test case
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-15T18:11:18.609669+02:00\""
closed-at: "2026-01-16T10:18:07.810509+02:00"
blocks:
  - pez-add-match-statement-31671795
---

Create test .py file with match guards:
  match x:
      case y if y > 0: print('pos')
      case z if z < 0: print('neg')
      case _: print('zero')
Compile with Python 3.10+ to get .pyc
Disassemble to understand bytecode pattern.
