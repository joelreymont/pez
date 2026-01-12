---
title: Fix return None at module level
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-11T21:53:38.789360+02:00\""
closed-at: "2026-01-11T21:56:43.847920+02:00"
---

test_for_loop_py3.8.3.10 and while_loops2.3.1 emit 'return None' at module level which is invalid Python. Need to suppress or convert to pass.
