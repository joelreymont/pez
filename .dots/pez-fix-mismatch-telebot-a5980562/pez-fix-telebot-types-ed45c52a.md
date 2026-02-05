---
title: Fix telebot types root cause
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-05T21:25:22.506082+01:00\""
closed-at: "2026-02-05T22:27:33.514777+01:00"
close-reason: completed
blocks:
  - pez-locate-telebot-types-79a9705f
---

Context: src/decompile.zig:13819, src/decompile.zig:19717; cause: decompiler control/stack/handler logic mismatch for telebot types; fix: implement root-cause AST/control-flow correction without fallbacks; deps: pez-locate-telebot-types-79a9705f; verification: target compare_driver unit semantic_score=1.0.
