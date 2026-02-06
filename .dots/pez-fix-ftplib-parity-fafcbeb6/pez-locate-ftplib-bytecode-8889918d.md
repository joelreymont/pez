---
title: Locate ftplib bytecode divergence
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T12:50:20.269094+01:00\""
closed-at: "2026-02-06T12:57:06.501960+01:00"
close-reason: implemented in 347078de
blocks:
  - pez-repro-ftplib-parse257-4561d444
---

Context: tools/compare/locate_mismatch.py; cause: unknown first opcode mismatch in parse257; fix: run locate_mismatch and map differing block edges; deps: pez-repro-ftplib-parse257-4561d444; verification: /tmp/ftplib-locate.json first mismatch recorded
