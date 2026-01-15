---
title: Create try/finally test cases
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-15T16:55:50.987503+02:00\\\"\""
closed-at: "2026-01-15T17:18:23.723421+02:00"
close-reason: Created test file with 7 test cases covering simple finally, try/except/finally, all 4 blocks, nesting, exception propagation, break/continue. Analyzed Python 3.14 bytecode - finally blocks appear duplicated (normal + exception paths), detected via exception table RERAISE handlers. Documented pattern in /tmp/finally_detection_notes.md
---

Create /tmp/try_finally.py with:
1. Simple try/finally
2. try/except/finally
3. try/except/else/finally (all 4)
4. Nested try in finally
Compile to .pyc for Python 2.7, 3.8, 3.11, 3.14. Study bytecode - finally must execute on ALL paths (normal, exception, return). Document detection pattern.
