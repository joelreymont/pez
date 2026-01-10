---
title: Implement KW_NAMES handling (3.11+)
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-10T06:36:20.265742+02:00\\\"\""
closed-at: "2026-01-10T07:13:55.164547+02:00"
---

File: src/stack.zig (simulate() for CALL opcode). Opcode: CALL with preceding KW_NAMES. Stack effect: KW_NAMES loads tuple of kwarg names from consts. CALL uses it for kwargs. Semantics: 3.11+ unified call instruction with kwarg names as metadata. Test file: test_kwnames.3.11.pyc. Implementation: 1) Track KW_NAMES value as call metadata, 2) In CALL handler, check for kwarg names, 3) Build kwargs from names+values. Priority: P1-HIGH.
