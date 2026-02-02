---
title: boat_main const tuple
status: active
priority: 2
issue-type: task
created-at: "\"2026-02-02T22:51:56.742396+01:00\""
---

Full context: src/emit.zig/src/consts.zig; telebot mismatch uses EXTENDED_ARG + LOAD_CONST tuple vs BUILD_TUPLE; cause missing tuple-const folding/emission; fix: emit const tuple when available to match bytecode; why: parity/perf.
