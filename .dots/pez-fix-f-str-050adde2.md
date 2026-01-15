---
title: Fix f-string debug syntax
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T07:21:22.116417+02:00"
---

f'{x=}' crashes on FORMAT_SIMPLE. Need to handle the = flag in f-string formatting.
