---
title: Verify Python 3.14 opcode coverage
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:01:08.794756+02:00\""
closed-at: "2026-01-16T10:19:22.218531+02:00"
---

Files: src/opcodes.zig and test suite
Change: Comprehensive testing of all Python 3.14 opcodes
- HAVE_ARGUMENT changed to 43 (was 90)
- Renumbered opcodes may affect decompilation
- Test all 3.14-specific features
Verify: Full pycdc test suite for 3.14 files passes
