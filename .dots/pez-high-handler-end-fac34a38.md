---
title: [HIGH] handler-end
status: open
priority: 2
issue-type: task
created-at: "2026-01-30T12:56:03.491546+01:00"
---

Full context: src/decompile.zig:15397; cause: +10 scan limit can truncate handler body; fix: compute handler end via CFG/exception entries; remove magic limit; add test.
