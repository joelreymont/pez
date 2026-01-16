---
title: "Fix spurious 'global' declarations"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T06:56:51.656243+02:00\""
closed-at: "2026-01-16T06:57:24.807348+02:00"
---

src/decompile.zig:5293 - Remove LOAD_GLOBAL from global detection, only STORE_GLOBAL should generate 'global' statements
