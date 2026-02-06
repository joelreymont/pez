---
title: Fix glob root cause
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T12:38:16.117870+01:00\""
closed-at: "2026-02-06T12:49:08.391190+01:00"
close-reason: implemented in 9f96c628
blocks:
  - pez-locate-glob-mismatch-a433c93e
---

Context: src/decompile.zig and related rewrite pass; cause: emitted structure diverges from source bytecode semantics for glob unit; fix: implement targeted rewrite with no fallback masking; deps: pez-locate-glob-mismatch-a433c93e; verification: compare_driver unit exact
