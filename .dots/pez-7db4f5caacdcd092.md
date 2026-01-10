---
title: Fix comprehension decompilation
status: open
priority: 2
issue-type: task
created-at: "2026-01-10T06:36:56.686052+02:00"
---

File: src/decompile.zig (decompileNestedBody for <listcomp>, etc.), src/stack.zig (LIST_APPEND, SET_ADD, MAP_ADD in loops). Current status: Some comprehensions work, others fail. Issues: 1) Nested comprehension scopes not handled, 2) Iterator unpacking in comprehensions, 3) Conditional comprehensions (if clause). Implementation: 1) Detect comprehension pattern (code.name == '<listcomp>'), 2) Extract iteration vars and conditions, 3) Generate comprehension syntax not for-loop. Test: create list/dict/set comprehension fixtures. Priority: P2-MEDIUM.
