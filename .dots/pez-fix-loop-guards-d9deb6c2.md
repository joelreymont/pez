---
title: Fix loop guards
status: active
priority: 2
issue-type: task
created-at: "\"2026-01-29T12:29:56.356159+01:00\""
---

Context: src/decompile.zig:20640; cause: loop guard snapshots show misplaced pass/indent and malformed conditions; fix: audit loop-guard insertion + if/continue stitching; deps: Fix stack flow; verification: zig build test -- --test-filter 'snapshot loop guard 3.9'.
