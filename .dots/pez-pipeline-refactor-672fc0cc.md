---
title: pipeline refactor
status: open
priority: 3
issue-type: task
created-at: "2026-01-24T12:38:54.050379+02:00"
---

Full context: src/decompile.zig:5600 decompileStructuredRange; cause: analysis/structure/emit interleaved; fix: split into passes (regions, expressions, stmt selection, canonicalize, emit); why: debuggability + determinism.
