---
title: Improve pez test coverage
status: active
priority: 2
issue-type: task
created-at: "\"\\\"\\\\\\\"2026-01-10T18:08:37.052345+02:00\\\\\\\"\\\"\""
---

Working on improving decompiler test coverage.

Current status (golden tests): 12 matched, 147 mismatched, 1 error (190 total)
Baseline was: 12 matched, 129 mismatched, 19 errors

WIP changes reduced crashes from 19 to 1. Those 18 now produce output but don't match golden.

Many "mismatches" are formatting differences (tabs/spaces, quotes, parens).
Real issues: chained assignments expanded, some incomplete patterns.

Unit tests: 108/108 passing (0 memory leaks)
Golden tests: 190/190 decompile successfully (0 errors)

Output quality: Many mismatches vs expected are formatting differences
(single vs double quotes, parens). Real issues include async for being
decompiled as try/except with yield from (not recognized as async for).

Next: Improve output quality or close dot
