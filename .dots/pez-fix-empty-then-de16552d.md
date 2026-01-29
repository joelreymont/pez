---
title: Fix empty-then invert
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T17:55:00.957337+01:00"
---

Context: src/decompile.zig:8795; cause: guard inversion emits if-not with dropped else; fix: remove/gate if_invert_empty_then to preserve pass/else; deps: none; verification: zig build run -- test/corpus/loop_guard.3.9.pyc
