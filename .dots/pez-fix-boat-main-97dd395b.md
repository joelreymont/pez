---
title: Fix boat_main decompile mismatches
status: active
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-22T19:47:19.762312+02:00\\\"\""
---

src/decompile.zig: loopIfParts/merge selection; cause: merge chosen as if-end (block19) instead of common successor (block25) so append sits inside else; fix: use loopIfMergeFromEnd+postdom to force merge at common successor; proof: compare_driver <module>.sensors_temperatures matches
