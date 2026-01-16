---
title: Test async/await edge cases
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-15T19:01:07.873473+02:00\""
closed-at: "2026-01-16T10:19:16.804873+02:00"
---

Files: test suite for async operations
Change: Create comprehensive test coverage for:
- SEND opcode generator protocol
- GET_AWAITABLE + YIELD_FROM combination
- Async generators (async def with yield)
- Complex await patterns with exceptions
Dependency: After pez-init-exc-handler-a0060c5e (exception handler stack)
Verify: All async test cases decompile and round-trip
