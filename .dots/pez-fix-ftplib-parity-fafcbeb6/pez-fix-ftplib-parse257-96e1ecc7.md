---
title: Fix ftplib parse257 root cause
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T12:50:26.207936+01:00\""
closed-at: "2026-02-06T12:57:06.505007+01:00"
close-reason: implemented in 347078de
blocks:
  - pez-locate-ftplib-bytecode-8889918d
---

Context: src/decompile.zig rewrite pipeline; cause: structural emission differs from parse257 source semantics; fix: targeted AST/CFG rewrite with no fallback masking; deps: pez-locate-ftplib-bytecode-8889918d; verification: compare_driver exact for parse257
