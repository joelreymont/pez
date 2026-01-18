---
title: Meta invariants check
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:35:12.005355+02:00\\\"\""
closed-at: "2026-01-18T10:42:56.323009+02:00"
close-reason: completed
---

Refines dot: pez-add-stack-effect-3e549a3b. File: tools/compare/compare.py:300-360. Root cause: no signature/closure checks. Fix: compare argcounts/posonly/kwonly, flags, stacksize, freevars/cellvars, varnames length; treat as hard mismatches.
