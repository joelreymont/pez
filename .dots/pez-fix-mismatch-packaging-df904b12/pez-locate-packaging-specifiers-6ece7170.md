---
title: Locate packaging specifiers divergence
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.554759+01:00\""
closed-at: "2026-02-06T01:01:01.822236+01:00"
close-reason: Located first divergence in <module>.Specifier.filter and captured /tmp/packaging_specifiers_filter.locate23.json and /tmp/packaging_specifiers_filter.unit23.json.
blocks:
  - pez-repro-packaging-specifiers-c33da8c6
---

Context: tools/compare/locate_mismatch.py:1, tools/compare/unit_trace.py:1; cause: first divergence and CFG delta unknown; fix: run locate_mismatch+unit_trace and map diverging block/edge signatures; deps: pez-repro-packaging-specifiers-c33da8c6; verification: locate/unittrace artifacts for packaging specifiers written to /tmp.
