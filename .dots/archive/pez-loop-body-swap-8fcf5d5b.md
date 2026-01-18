---
title: Loop body swap verify
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T14:49:21.296468+02:00\\\"\""
closed-at: "2026-01-18T15:09:02.394599+02:00"
close-reason: completed
---

Full context: src/ctrl.zig:961-967 detectWhilePattern swaps body/exit when loop edge flipped; cause: conditional-true/false reversed for some while CFGs (bot_get_files_from_dir); fix: verify swap correctness via tests and target decompile; proof: compare output improves.
