---
title: Locate ftplib divergence
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.605846+01:00\""
closed-at: "2026-02-06T02:50:48.467081+01:00"
close-reason: locate/unit analysis completed; sentinel-loop root found
blocks:
  - pez-repro-ftplib-3f292785
---

Context: tools/compare/locate_mismatch.py:1, tools/compare/unit_trace.py:1; cause: first divergence and CFG delta unknown; fix: run locate_mismatch+unit_trace and map diverging block/edge signatures; deps: pez-repro-ftplib-3f292785; verification: locate/unittrace artifacts for ftplib written to /tmp.
