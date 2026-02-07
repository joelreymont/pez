---
title: Fix mismatch bootsubprocess
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-07T02:45:47.557584+01:00\""
closed-at: "2026-02-07T02:45:59.029070+01:00"
close-reason: implemented and committed in jj 600f9bb4
---

File: /Users/joel/Work/pez/src/decompile.zig:12362,286,366; cause: with-body emits duplicate trailing empty-bytes assign after subprocess check_output write path; fix: rewriteDropPostWithEmptyAssign* removes post-with x=b'' when with body already assigns same target; proof: zig build test pass, /tmp/bootsubprocess-after5.json min_sem=0.585714 (from 0.54 baseline)
