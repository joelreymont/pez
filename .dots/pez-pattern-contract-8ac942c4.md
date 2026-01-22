---
title: pattern contract
status: open
priority: 2
issue-type: task
created-at: "2026-01-24T12:38:39.058381+02:00"
---

Full context: src/decompile.zig:5634 detectPattern calls; cause: decompile re-detects patterns leading to divergence from ctrl; fix: make ctrl authoritative (single pass) and remove re-detection in decompile; why: consistency and less heuristic branching.
