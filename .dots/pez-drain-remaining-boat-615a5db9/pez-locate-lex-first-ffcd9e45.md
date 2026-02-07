---
title: Locate lex first divergence
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-07T09:49:16.143013+01:00\\\"\""
closed-at: "2026-02-07T09:54:29.648013+01:00"
close-reason: located divergence at <module>.lex offset 244
blocks:
  - pez-repro-pycparser-lex-3890f864
---

Files: tools/compare/locate_mismatch.py + compare_driver rows for <module>.lex; cause: unknown first structural split; fix: locate earliest cfg/edge drift and map to source region; why: root-cause targeting.
