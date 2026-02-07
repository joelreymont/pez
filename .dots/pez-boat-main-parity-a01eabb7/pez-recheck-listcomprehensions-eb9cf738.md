---
title: Recheck listComprehensions crash regression
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-02-07T09:49:04.665069+01:00\\\"\""
closed-at: "2026-02-07T09:55:58.079330+01:00"
close-reason: "pass: rc=0 no timeout (/tmp/pez-historical-regression-check.json)"
blocks:
  - pez-drain-remaining-boat-615a5db9
---

File: test/hello.pyc + historical fixture test_listComprehensions.2.7.pyc; cause: invalid-free regression historically seen; fix: rerun and add dedicated regression if needed; why: prevent crash relapses.
