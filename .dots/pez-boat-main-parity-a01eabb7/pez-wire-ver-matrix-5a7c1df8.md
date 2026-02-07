---
title: Wire version-matrix parity runs
status: open
priority: 2
issue-type: task
created-at: "2026-02-07T09:49:04.681504+01:00"
blocks:
  - pez-expand-prop-invariants-d1dac452
---

Files: test_matrix.sh + tools/parity/run.sh + build.zig; cause: supported opcode tables not exercised systematically; fix: add matrix execution over supported versions in CI/local scripts; why: detect version-specific regressions early.
