---
title: Repro subprocess _wait
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-06T13:33:29.253688+01:00\\\"\""
closed-at: "2026-02-06T14:00:31.140593+01:00"
close-reason: Reproduced and localized _wait mismatch; first divergence at POP_JUMP target in run of lock/finally path; implemented and committed fix+tests in 97cba021
---

Context: locate first mismatch for <module>.Popen._wait (index 1) and map AST cause
