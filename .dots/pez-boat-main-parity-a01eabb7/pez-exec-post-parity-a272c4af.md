---
title: Execute post-parity architecture backlog
status: open
priority: 3
issue-type: task
created-at: "2026-02-07T09:49:04.689679+01:00"
blocks:
  - pez-run-final-parity-590494c5
---

Files: src/cfg.zig + src/decompile.zig + src/stack.zig + docs/decompiler-design.md; cause: deferred architecture items (postdom/pattern contract/staged pipeline) remain; fix: implement after parity gate passes; why: long-term maintainability/perf.
