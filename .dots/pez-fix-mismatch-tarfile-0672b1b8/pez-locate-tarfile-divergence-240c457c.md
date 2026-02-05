---
title: Locate tarfile divergence
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-02-05T21:25:22.520298+01:00\\\"\""
closed-at: "2026-02-05T22:30:18.007851+01:00"
close-reason: first divergence at <module>.TarInfo._create_pax_generic_header with handler scope inflation
blocks:
  - pez-repro-tarfile-a50c35fa
---

Context: tools/compare/locate_mismatch.py:1, tools/compare/unit_trace.py:1; cause: first divergence and CFG delta unknown; fix: run locate_mismatch+unit_trace and map diverging block/edge signatures; deps: pez-repro-tarfile-a50c35fa; verification: locate/unittrace artifacts for tarfile written to /tmp.
