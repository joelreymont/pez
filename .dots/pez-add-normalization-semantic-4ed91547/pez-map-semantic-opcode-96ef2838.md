---
title: Map semantic opcode classes
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:33:05.692419+02:00\\\"\""
closed-at: "2026-01-18T10:41:35.013107+02:00"
close-reason: completed
---

File: tools/compare/compare.py:1-120. Root cause: opnames too granular. Fix: add semantic class map (load/store/call/binop/branch/return/raise/compare/const/name) + known equivalents (ROT/SWAP/COPY/DUP, BINARY_OP variants).
