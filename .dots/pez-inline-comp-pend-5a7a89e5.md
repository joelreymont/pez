---
title: Inline comp pend
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T12:12:28.352817+01:00"
---

Context: src/decompile.zig:3065; cause: pending ternary/inline comp exprs collide across blocks and cleanup ops; fix: complete inline_pend push/skip logic for pre-3.14 and 3.14, remove global pending collisions; deps: Capture failures; verification: pycdc tests for listComprehensions.2.7 + snapshots.
