---
title: Tiered verdict + diffs
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:35:23.539992+02:00\\\"\""
closed-at: "2026-01-18T10:43:30.320338+02:00"
close-reason: completed
---

Refines dot: pez-semantic-scoring-diagnostics-ad8900e9. File: tools/compare/compare.py:440-520. Root cause: no actionable diffs. Fix: produce tiered verdicts (exact/cfg_equiv/semantic_equiv/mismatch) and report missing/excess signatures, edge diffs, and stack profile deltas.
