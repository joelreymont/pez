---
title: Patch lex divergence root cause
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-07T09:49:16.147061+01:00\""
closed-at: "2026-02-07T10:05:22.585691+01:00"
close-reason: implemented in d54c589d; <module>.lex now exact in compare_driver
blocks:
  - pez-locate-lex-first-ffcd9e45
---

Files: src/stack.zig and/or src/decompile.zig; cause: incorrect control-flow/ifexp capture in lex path; fix: implement root-cause logic change without fallback masking; why: parity improvement.
