---
title: expr graph
status: open
priority: 2
issue-type: task
created-at: "2026-01-24T12:38:48.274850+02:00"
---

Full context: src/stack.zig:1 + src/decompile.zig:6000; cause: expressions rebuilt per emission; fix: build expression DAG/value numbering once and reuse across blocks; why: fewer mismatches and faster decompile.
