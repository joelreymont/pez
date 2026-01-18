---
title: Add unit diff tool
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T11:21:59.728124+02:00\\\"\""
closed-at: "2026-01-18T11:26:56.285069+02:00"
close-reason: completed
---

Full context: tools/compare/unit_diff.py:1, tools/compare/compare.py:1. Cause: compare summary lacks per-unit raw opcode diff for debugging mismatches. Fix: add unit_diff tool to extract code object by path and dump raw+normalized instructions and CFG signatures for orig vs compiled; update compare skill triggers/docs; add tests.
