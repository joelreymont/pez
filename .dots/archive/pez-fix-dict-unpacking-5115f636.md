---
title: Fix dict unpacking merge
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-15T07:21:22.110766+02:00\\\"\""
closed-at: "2026-01-15T15:09:38.928686+02:00"
close-reason: "DICT_UPDATE now merges starred dicts into target dict in stack.zig:3987, extending keys/values arrays with null key entries"
---

{**a, **b} shows as {}. Check BUILD_MAP with DICT_UPDATE/DICT_MERGE handling.
