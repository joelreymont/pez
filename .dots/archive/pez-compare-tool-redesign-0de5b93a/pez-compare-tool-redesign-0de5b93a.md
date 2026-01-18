---
title: Compare tool redesign plan
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-18T10:32:20.827002+02:00\""
closed-at: "2026-01-18T10:53:56.202492+02:00"
close-reason: completed
---

Context: tools/compare/compare.py:1, tools/compare/compare_dir.py:1. Root cause: sequence/Jaccard metrics ignore CFG/stack semantics. Goal: implement CFG+semantic compare with actionable diagnostics and tiered verdicts.
