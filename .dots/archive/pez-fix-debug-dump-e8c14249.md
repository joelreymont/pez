---
title: Fix debug_dump error set
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T07:28:58.332691+02:00\\\"\""
closed-at: "2026-01-18T07:30:18.818586+02:00"
close-reason: done
---

Full context: zig build fails at src/debug_dump.zig:294: unable to resolve inferred error set in buildCodeDump recursion; root cause: inferred error set too complex; fix: add explicit error set return type for buildCodeDump/dumpModule or annotate try with explicit error union; why: unblocks zig build and tooling.
