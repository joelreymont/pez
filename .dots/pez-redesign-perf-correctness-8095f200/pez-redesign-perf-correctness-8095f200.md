---
title: Redesign perf/correctness
status: open
priority: 1
issue-type: task
created-at: "2026-01-17T22:29:31.347983+02:00"
---

Context: src/decompile.zig, src/ctrl.zig; root cause: repeated sim allocations, error masking, no pattern cache; fix: add scratch allocators, cache pattern results, strict error propagation; goal: perf+correctness
