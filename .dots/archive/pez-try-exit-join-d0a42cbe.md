---
title: Try exit join
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T17:18:19.179487+02:00\\\"\""
closed-at: "2026-01-17T17:18:28.459863+02:00"
close-reason: completed
---

Full context: src/decompile.zig:4250-4270; cause: effective_exit fell back to post_try_entry when exit_block missing, collapsing else; fix: prefer join_block as fallback before post_try_entry.
