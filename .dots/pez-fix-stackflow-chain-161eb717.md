---
title: Fix stackflow chain
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T17:55:17.534076+01:00"
---

Context: src/stack_flow.zig (deep jump chain handling); cause: test stack flow handles deep jump chain fails; fix: correct traversal/stack propagation for long chains; deps: run failing test to locate; verification: zig test src/stack_flow_tests.zig --test-filter "deep jump chain"
