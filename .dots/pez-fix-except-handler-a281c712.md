---
title: Fix except handler cleanup code visibility
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T09:08:17.711857+02:00"
---

Handler bodies show cleanup code (STORE_NAME e=None, DELETE_NAME e, POP_EXCEPT, RETURN_VALUE) instead of just user code. Need to detect POP_EXCEPT and stop decompiling handler body there. File: src/decompile.zig:3906, decompileTry311 function, decompileBlockRangeWithStackAndSkip call for handler_body.
