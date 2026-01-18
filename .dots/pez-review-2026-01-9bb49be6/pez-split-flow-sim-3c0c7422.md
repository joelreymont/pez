---
title: Split flow sim
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T06:54:42.477196+02:00"
---

Full context: src/stack.zig:337-360,383-395 allow_underflow synthesizes unknowns. Root cause: same Stack used for strict and lenient passes. Fix: split FlowSimContext/StrictSimContext or explicit underflow policy + counters; avoid silent fallback in main path. Why: correctness and compare fidelity.
