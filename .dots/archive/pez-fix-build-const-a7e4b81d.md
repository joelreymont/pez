---
title: Fix BUILD_CONST_KEY_MAP stack order
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T18:19:06.774285+02:00\""
closed-at: "2026-01-15T18:20:47.161170+02:00"
---

src/stack.zig:3458 - BUILD_CONST_KEY_MAP pops keys first, but values are pushed after keys. Stack order: [... keys_tuple value1 value2 ... valueN] - must pop values BEFORE keys. Fix: swap pop order in handler.
