---
title: "Phase 1: Fix Python 1.5-2.2 16-bit marshal fields"
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T18:23:48.057788+02:00"
---

src/pyc.zig:849-872 - Add version checks for 16-bit argcount/nlocals/stacksize/flags in Python 1.5-2.2 (currently reads 32-bit, causing all 40+ files to output 'def (): pass'). Python 2.3+ uses 32-bit, 1.5-2.2 uses 16-bit.
