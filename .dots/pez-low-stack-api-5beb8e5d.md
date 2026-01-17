---
title: [LOW] stack API bypass
status: open
priority: 3
issue-type: task
created-at: "2026-01-17T08:40:48.174458+02:00"
---

src/decompile.zig:4149; decompileWith peeks sim.stack.items.items directly. Add Stack.peekExpr()/peekValue helper and avoid raw access to preserve invariants.
