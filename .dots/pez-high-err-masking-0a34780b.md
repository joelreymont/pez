---
title: [HIGH] error masking
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T22:12:33.998238+02:00"
---

Full context: src/decompile.zig:1614 and src/pyc.zig:159. Cause: error-masking patterns (catch return/null) hide real decode/sim errors, producing silent corruption. Fix: replace with error unions and explicit PatternNoMatch/InvalidStack errors; propagate and surface in diagnostics; remove catch return/unreachable patterns.
