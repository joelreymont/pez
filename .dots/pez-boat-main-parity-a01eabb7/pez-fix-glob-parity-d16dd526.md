---
title: Fix glob parity
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T12:37:59.835999+01:00\""
closed-at: "2026-02-06T12:49:08.400261+01:00"
close-reason: implemented in 9f96c628
---

Context: /tmp/pez-boatmain-suite20/pez_compare.json; cause: glob.pyc verdict=close, min_semantic_score=0.5433; fix: isolate first divergent unit and normalize control-flow/AST rewrite; deps: none; verification: compare_driver exact for glob.pyc
