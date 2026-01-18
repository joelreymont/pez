---
title: Block signature + multiset scoring
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T10:35:17.970364+02:00\\\"\""
closed-at: "2026-01-18T10:43:17.957954+02:00"
close-reason: completed
---

Refines dot: pez-semantic-scoring-diagnostics-ad8900e9. File: tools/compare/compare.py:360-440. Root cause: no semantic score. Fix: hash block signatures (op-class seq + stack delta/max + const/name multiset) and compute multiset Jaccard; edge signature Jaccard.
