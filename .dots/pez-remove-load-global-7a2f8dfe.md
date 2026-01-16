---
title: Remove LOAD_GLOBAL from condition
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T08:02:06.093590+02:00"
---

File: src/decompile.zig:5293
Change condition from:
  if (inst.opcode == .STORE_GLOBAL or inst.opcode == .LOAD_GLOBAL)
To:
  if (inst.opcode == .STORE_GLOBAL)
Only generate global declarations for stores, not reads
Dependencies: pez-find-global-declaration-80f69d35
Verify: zig build test
