---
title: Locate glob mismatch unit
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T12:38:11.304987+01:00\""
closed-at: "2026-02-06T12:49:08.388042+01:00"
close-reason: implemented in 9f96c628
blocks:
  - pez-repro-glob-divergence-f3a0aad9
---

Context: /tmp/glob-driver.json + tools/compare/locate_mismatch.py; cause: unknown first bytecode divergence; fix: locate_mismatch on worst unit path; deps: pez-repro-glob-divergence-f3a0aad9; verification: mismatch report identifies block/op divergence
