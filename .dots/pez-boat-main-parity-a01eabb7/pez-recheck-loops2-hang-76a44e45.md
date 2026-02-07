---
title: Recheck loops2 hang regression
status: open
priority: 2
issue-type: task
created-at: "2026-02-07T09:49:04.669314+01:00"
blocks:
  - pez-drain-remaining-boat-615a5db9
---

File: historical fixture test_loops2.2.2.pyc; cause: hang regression historically seen; fix: rerun bounded command and add guard regression on recurrence; why: prevent non-termination relapses.
