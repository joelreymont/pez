---
title: Fix try merges
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T12:29:56.359965+01:00"
---

Context: src/decompile.zig:18124; cause: try/if merge snapshots show bad else placement/extra blank lines; fix: rework try merge decision + block emission; deps: Fix loop guards; verification: zig build test -- --test-filter 'snapshot try if merge 3.9'.
