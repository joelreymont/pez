---
title: Generate imports
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-07T17:41:08.936656+02:00\\\"\""
closed-at: "2026-01-10T05:54:19.774092+02:00"
close-reason: "Partial: Added ImportModule type, IMPORT_NAME handler. Need multi-instruction pattern for IMPORT_FROM (accumulate names across multiple IMPORT_FROM->STORE_NAME pairs). Requires pattern matching in decompiler."
---

File: src/codegen.zig - IMPORT_NAME, IMPORT_FROM, IMPORT_STAR. Handle: import x, from x import y, from x import *, import x as y.
