---
title: Locate glob divergence
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.623781+01:00\""
closed-at: "2026-02-06T09:32:11.417577+01:00"
close-reason: first divergence traced to lost if_next at merge boundary
blocks:
  - pez-repro-glob-a2ef77e1
---

Context: tools/compare/locate_mismatch.py:1, tools/compare/unit_trace.py:1; cause: first divergence and CFG delta unknown; fix: run locate_mismatch+unit_trace and map diverging block/edge signatures; deps: pez-repro-glob-a2ef77e1; verification: locate/unittrace artifacts for glob written to /tmp.
