---
title: Match guard body extraction fix
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T11:24:27.185079+02:00\""
closed-at: "2026-01-16T11:30:58.870503+02:00"
---

Fix inline body extraction for match guards. Issue: bodies are inline in same block after POP_TOP, not in separate blocks. Need to handle stack state correctly when extracting bodies. Current error at offset 20 (POP_TOP) with StackUnderflow. Files: src/decompile.zig:3857-3956. Root cause: decompileStructuredRange called with empty stack but block expects subject on stack from COPY. Solution: extract all match case bodies inline, simulate from POP_TOP onwards.
