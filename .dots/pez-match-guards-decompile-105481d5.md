---
title: Match guards decompile as if-elif chains
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T07:59:39.741235+02:00"
---

Match statements with guards compile to if-elif-else chains in Python 3.14. Subject must stay on stack through the chain. Need to fix elif handling in src/decompile.zig:2976-3009 to preserve base_vals for match guard patterns. Also fixed allowsEmptyPop for NOT_TAKEN prefix and STORE_FAST_LOAD_FAST order in stack.zig.
