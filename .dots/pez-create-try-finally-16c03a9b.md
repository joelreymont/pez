---
title: Create try/finally test cases
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T16:55:50.987503+02:00"
---

Create /tmp/try_finally.py with:
1. Simple try/finally
2. try/except/finally
3. try/except/else/finally (all 4)
4. Nested try in finally
Compile to .pyc for Python 2.7, 3.8, 3.11, 3.14. Study bytecode - finally must execute on ALL paths (normal, exception, return). Document detection pattern.
