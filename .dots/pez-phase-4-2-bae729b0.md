---
title: "Phase 4.2: Remove LOAD_GLOBAL from condition"
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:48:08.297905+02:00"
---

src/decompile.zig:5293 - Change 'if (inst.opcode == .STORE_GLOBAL or inst.opcode == .LOAD_GLOBAL)' to 'if (inst.opcode == .STORE_GLOBAL)'
