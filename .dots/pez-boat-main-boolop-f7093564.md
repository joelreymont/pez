---
title: boat_main boolop
status: open
priority: 2
issue-type: task
created-at: "2026-02-02T22:15:02.005402+01:00"
---

Full context: src/decompile.zig:8231-10090, src/sc_pass.zig:948-1080 - cause: boolop/chain/guard CF mismatches; fix: adjust cond folding/chain compare/or-pop handling and add snapshots; why: large share of semantic mismatches.
