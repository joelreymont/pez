---
title: Fix match pattern extraction for 3.14
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:48:06.341151+02:00"
---

src/decompile.zig:extractMatchPatternFromInsts: Fix NotAnExpression.
- Python 3.14 uses different bytecode for pattern matching
- walrus.3.14.pyc fails in pattern extraction
- Trace bytecode sequence, update pattern recognition
- Depends: match literal case fix
- Verify: ./zig-out/bin/pez test/corpus/walrus.3.14.pyc
