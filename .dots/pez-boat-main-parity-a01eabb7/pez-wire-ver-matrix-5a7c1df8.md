---
title: Wire version-matrix parity runs
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-07T09:49:04.681504+01:00\""
closed-at: "2026-02-07T10:07:05.102515+01:00"
close-reason: implemented via build.zig matrix/parity steps and parity runner matrix hook
blocks:
  - pez-expand-prop-invariants-d1dac452
---

Files: test_matrix.sh + tools/parity/run.sh + build.zig; cause: supported opcode tables not exercised systematically; fix: add matrix execution over supported versions in CI/local scripts; why: detect version-specific regressions early.
