---
title: Detect inline comprehension cleanup pattern
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T13:46:27.215356+02:00\""
closed-at: "2026-01-16T13:55:22.806982+02:00"
---

src/ctrl.zig:detectTryPattern: Skip PEP 709 inline comprehension cleanup.
- Check if protected block has LOAD_FAST_AND_CLEAR + BUILD_LIST
- Check if handler is cleanup: SWAP + POP_TOP + SWAP + STORE_FAST + RERAISE
- If both: return null (no try pattern)
- Unblocks: comprehensions.3.14, generators.3.14, pep_709_comprehensions.3.14
- Verify: ./zig-out/bin/pez test/corpus/comprehensions.3.14.pyc
