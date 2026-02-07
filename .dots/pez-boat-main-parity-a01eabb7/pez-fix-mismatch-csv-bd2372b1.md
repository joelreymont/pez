---
title: Fix mismatch csv guess_delimiter
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-07T02:08:52.366540+01:00\\\"\""
closed-at: "2026-02-07T02:58:22.776108+01:00"
close-reason: completed in jj 846494a1640a
---

Full context: boat_main suite28 still reports csv.pyc mismatch with min_semantic_score=0.7965. Cause: control-flow divergence in <module>.Sniffer._guess_delimiter. Fix: compare_driver + locate_mismatch + targeted AST rewrite + snapshot regression. Proof: csv.pyc compare exact and suite mismatch decremented.
