---
title: Locate subprocess divergence
status: active
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.537464+01:00\""
blocks:
  - pez-repro-subprocess-ae569d1f
---

Context: tools/compare/locate_mismatch.py:1, tools/compare/unit_trace.py:1; cause: first divergence and CFG delta unknown; fix: run locate_mismatch+unit_trace and map diverging block/edge signatures; deps: pez-repro-subprocess-ae569d1f; verification: locate/unittrace artifacts for subprocess written to /tmp.
