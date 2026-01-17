---
title: [HIGH] kw-defaults lost
status: open
priority: 2
issue-type: task
created-at: "2026-01-17T08:40:42.109281+02:00"
---

src/stack.zig:1026; parseKwDefaults drops kw-only defaults, causing incorrect signatures vs pycdc/uncompyle6. Implement dict extraction + ast.Keyword defaults and codegen emission.
