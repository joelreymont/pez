---
title: Adjust match case stack init by is_first_case
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:51:27.916061+02:00"
---

src/decompile.zig:decompileMatchCase: Fix stack.
- If first case: init body stack with 1 item (subject)
- If not first: init with empty or based on prev compare
- Depends: is_first_case param, callers updated
- Unblocks: pep_634_match.3.14.pyc
- Verify: ./zig-out/bin/pez test/corpus/pep_634_match.3.14.pyc
