---
title: Locate typing divergence
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.571759+01:00\""
closed-at: "2026-02-06T02:41:50.284234+01:00"
close-reason: locate/unit-diff work completed during typing root fixes
blocks:
  - pez-repro-typing-bf965941
---

Context: tools/compare/locate_mismatch.py:1, tools/compare/unit_trace.py:1; cause: first divergence and CFG delta unknown; fix: run locate_mismatch+unit_trace and map diverging block/edge signatures; deps: pez-repro-typing-bf965941; verification: locate/unittrace artifacts for typing written to /tmp.
