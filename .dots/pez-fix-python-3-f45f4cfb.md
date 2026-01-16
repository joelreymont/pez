---
title: Fix Python 3.14 annotation decompilation
status: open
priority: 1
issue-type: task
created-at: "2026-01-16T10:54:31.292917+02:00"
---

annotations.3.14.pyc fails with Invalid free. Python 3.14 uses new __annotate__ functions and __conditional_annotations__ set. Bytecode contains nested code objects that trigger memory issue during decompilation. May be related to SET_FUNCTION_ATTRIBUTE 16 (annotate) bytecode. File: test/corpus/annotations.3.14.pyc. Verify: file decompiles without crash.
