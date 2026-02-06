---
title: Fix tarfile add fallthrough
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T13:06:12.908524+01:00\""
closed-at: "2026-02-06T13:23:22.378368+01:00"
close-reason: implemented
blocks:
  - pez-repro-tarfile-add-3ea8c7f3
---

Context: src/decompile.zig if/elif rewrite pipeline; cause: else-body retained where continuation should be hoisted, emits extra JUMP_FORWARD; fix: targeted AST rewrite + tests; deps: pez-repro-tarfile-add-3ea8c7f3; verification: TarFile.add bytecode exact
