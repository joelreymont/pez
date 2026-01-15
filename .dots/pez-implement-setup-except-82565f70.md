---
title: Implement SETUP_EXCEPT/SETUP_FINALLY for old Python
status: open
priority: 2
issue-type: task
created-at: "2026-01-15T19:04:38.988710+02:00"
---

Files: src/decompile.zig
Change: Implement old-style exception opcodes for Python <3.8
- SETUP_EXCEPT: setup exception handler
- SETUP_FINALLY: setup finally block
- POP_BLOCK: end block
- Integrate with existing exception handling
Dependency: After pez-init-exc-handler-a0060c5e
Verify: Decompile Python 2.x/3.7 try/except
