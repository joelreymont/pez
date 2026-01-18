---
title: Unmangle class privates
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T08:21:59.946663+02:00\\\"\""
closed-at: "2026-01-18T08:55:49.515998+02:00"
close-reason: completed
---

Full context: datetime.pyc compare shows units_missing for date/time/datetime.__setstate; decompiled output emits _date__setstate/_time__setstate. Cause: class private name mangling not reversed in class bodies. Fix: detect store names matching _ClassName__X (without trailing __) and emit __X in class bodies.
