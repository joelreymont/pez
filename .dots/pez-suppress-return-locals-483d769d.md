---
title: "Suppress 'return locals()' in Python 2.x class bodies"
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:59:13.851826+02:00"
---

Files: src/decompile.zig (statement generation for class bodies)
Change: Detect LOAD_LOCALS + RETURN_VALUE pattern at end of class body
- Check if code object has class flags (0x42)
- Check if last 2 instructions are LOAD_LOCALS, RETURN_VALUE
- Suppress outputting this return statement
Verify: Decompile test_class.2.5.pyc, should not have 'return locals()' at end
