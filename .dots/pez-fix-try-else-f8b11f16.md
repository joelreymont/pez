---
title: Fix try else detect
status: active
priority: 1
issue-type: task
created-at: "\"2026-01-18T15:56:14.420264+02:00\""
---

Full context: src/ctrl.zig:1172-1341 detectElseBlock311/Legacy misclassifies post-try return blocks as try-else (boat_main bot_text_message_handler). Cause: candidate chosen from last_try_block successor even when it is the immediate post-try exit/return block with no real else. Fix: add guard to reject candidates that are the try-body normal exit block (POP_BLOCK/JUMP to exit/return) or that are post-try exit-only blocks; ensure else has distinct body reachable only on normal completion.
