---
title: if guard return invert
status: open
priority: 2
issue-type: task
created-at: "2026-01-23T13:19:28.948838+02:00"
---

src/decompile.zig:6881 root cause: decompileIf collapses else-as-fallthrough with terminal then into guard (if cond: return), flipping jump sense vs original (gather_candidates POP_JUMP_IF_TRUE). fix: when merge is then/terminal and else reaches merge, invert condition and move body into then with empty else so return stays as tail. why: preserve branch layout for bytecode parity.
