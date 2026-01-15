---
title: Test nested comprehensions
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:01:09.103226+02:00"
---

Files: test suite for comprehensions
Change: Add tests for edge cases:
- Nested list/set/dict comprehensions
- Multiple builders in single expression
- Generator expressions with side effects
- Comprehensions with complex conditions
Verify: All comprehension tests round-trip correctly
