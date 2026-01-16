---
title: Detect except* pattern in decompileTry311
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T13:46:47.051028+02:00"
---

src/decompile.zig:decompileTry311: Detect except* handlers.
- Handler starts with BUILD_LIST + COPY + CHECK_EG_MATCH
- Ends with CALL_INTRINSIC_2 PREP_RERAISE_STAR
- Set ExceptHandler.is_star = true when detected
- Depends: CHECK_EG_MATCH handler, CALL_INTRINSIC handlers, is_star field
- Verify: ./zig-out/bin/pez test/corpus/pep_654_exception_groups.3.14.pyc
