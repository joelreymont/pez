---
title: Create try/else test cases
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-15T16:55:32.907773+02:00\\\"\""
closed-at: "2026-01-15T17:06:32.099534+02:00"
close-reason: "Try/else detected: L1..L2 is try+else, L3+ is handler. Else misdetected as try body because L1->L2 normal edge crosses to post-handler L2. Need: detect L2 as else (unreachable from handlers, reached from try normal exit)."
---

Create /tmp/try_else.py with:
try:
    x = 1
except ValueError:
    pass
else:
    print('no error')

Compile to .pyc for Python 2.7, 3.8, 3.11, 3.14. Study bytecode/ExceptionTable structure. Document else block detection pattern for each version.
