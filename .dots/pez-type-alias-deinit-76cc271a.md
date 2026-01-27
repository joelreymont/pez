---
title: type-alias-deinit
status: open
priority: 2
issue-type: task
created-at: "2026-01-29T16:04:51.725618+01:00"
---

Full context: src/stack.zig:171-186; cause: StackValue.deinit ignores .type_alias, leaking marker expr outside arena contexts; fix: define ownership (arena-only) or deinit marker safely, add leak test.
