---
title: Support 3+ chained comparisons
status: open
priority: 2
issue-type: task
created-at: "2026-01-10T07:32:23.576361+02:00"
---

File: src/decompile.zig:tryDecompileChainedComparison. Current: Only handles 2-comparison chains (a<b<c). For longer chains (a<b<c<d), bytecode has nested if pattern: POP_TOP+LOAD+SWAP+COPY+COMPARE instead of just POP_TOP+LOAD+COMPARE. Need to: 1) Detect nested pattern recursively, 2) Accumulate all comparators and ops, 3) Build single Compare node with N comparators. Test: create test for a<b<c<d. Priority: P2-MEDIUM.
