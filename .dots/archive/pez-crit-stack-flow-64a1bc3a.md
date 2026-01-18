---
title: [CRIT] stack_flow clone cost
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T08:40:24.790341+02:00\\\"\""
closed-at: "2026-01-18T20:28:32.631343+02:00"
close-reason: "paused: minions stopped"
---

src/decompile.zig:543, src/stack.zig:912; stack_in uses deep cloneStackValue per block; pyimod02_importers.pyc >35s (sample shows Decompiler.init + cloneStackValue). Redesign stack flow to use stack-shape + shallow/value IDs or persistent stacks; avoid deep AST clones.
