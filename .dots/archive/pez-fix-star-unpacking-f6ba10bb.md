---
title: Fix star unpacking
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T07:21:22.119171+02:00"
---

a, *rest = [...] crashes. Need to handle UNPACK_EX opcode for extended unpacking.
