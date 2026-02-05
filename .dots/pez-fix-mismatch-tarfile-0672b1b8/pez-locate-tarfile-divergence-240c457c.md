---
title: Locate tarfile divergence
status: open
priority: 2
issue-type: task
created-at: "2026-02-05T21:25:22.520298+01:00"
blocks:
  - pez-repro-tarfile-a50c35fa
---

Context: tools/compare/locate_mismatch.py:1, tools/compare/unit_trace.py:1; cause: first divergence and CFG delta unknown; fix: run locate_mismatch+unit_trace and map diverging block/edge signatures; deps: pez-repro-tarfile-a50c35fa; verification: locate/unittrace artifacts for tarfile written to /tmp.
