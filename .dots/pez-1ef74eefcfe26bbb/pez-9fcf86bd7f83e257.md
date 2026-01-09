---
title: Fix COPY_DICT_WITHOUT_KEYS stack effect
status: open
priority: 2
issue-type: task
created-at: "2026-01-09T06:18:55.517616+02:00"
---

File: src/stack.zig:2505-2513. COPY_DICT_WITHOUT_KEYS currently pops only keys and pushes unknown, leaving the subject dict on the stack and leaking ownership. It should pop keys and subject, deinit both, then push the replacement value to keep stack depth correct and avoid leaks.
