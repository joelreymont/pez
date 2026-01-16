---
title: Complete match statement support
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T09:29:27.224616+02:00"
---

Implement MATCH_CLASS, MATCH_MAPPING, MATCH_SEQUENCE, MATCH_KEYS, COPY_DICT_WITHOUT_KEYS, GET_LEN. Complete pattern matching for all pattern types (literal, capture, wildcard, sequence, mapping, class, or, as). Validate guards. Files: src/match.zig or src/stack.zig. Dependencies: none. Verify: match statement tests pass.
