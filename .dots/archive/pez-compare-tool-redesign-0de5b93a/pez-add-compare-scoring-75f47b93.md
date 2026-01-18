---
title: Add compare scoring tests
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-18T10:44:44.463879+02:00\""
closed-at: "2026-01-18T10:45:34.765925+02:00"
close-reason: completed
---

Refines dot: pez-compare-tool-unit-8258c73e. Files: tools/compare/tests/run.py. Root cause: new semantic scoring untested. Fix: run compare.py on identical pyc/src and assert verdict exact or semantic_equiv with high scores.
