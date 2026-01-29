---
title: Fix loop if-chain
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T17:55:09.445772+01:00"
---

Context: src/decompile.zig (if/else merge around loop bodies); cause: else_body absorbs trailing stmt; fix: correct if_next/merge handling so post-else stmt stays in loop body; deps: after empty-then/align optional; verification: zig build run -- test/corpus/loop_if_chain.3.9.pyc
