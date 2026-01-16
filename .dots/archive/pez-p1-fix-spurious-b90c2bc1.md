---
title: "P1: Fix spurious 'global' for LOAD_GLOBAL"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:48:48.314619+02:00\""
closed-at: "2026-01-16T06:49:52.319409+02:00"
---

src/decompile.zig:5293 - Remove LOAD_GLOBAL from global detection, only STORE_GLOBAL should generate global declaration. Spec: Phase 4
