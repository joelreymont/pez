---
title: "P1: Keyword-only arguments not parsed"
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T21:47:47.883425+02:00"
---

test_functions_py3.3.0.pyc, 3.4.pyc: 'def x5a(*, bar=1)' becomes 'def x5a(bar)'. Root: function signature parsing missing kwonlyargcount handling.
