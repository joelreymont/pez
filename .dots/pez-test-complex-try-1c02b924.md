---
title: Test complex try/except/finally nesting
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:01:09.411582+02:00"
---

Files: test suite for exception handling
Change: Test edge cases found in pycdc suite:
- Multiple except handlers with type matching
- Nested try with multiple finally blocks
- Try/except in finally block
- Exception re-raising patterns
Dependency: After pez-init-exc-handler-a0060c5e
Verify: All exception nesting tests decompile without StackUnderflow
