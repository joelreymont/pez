---
title: Validate glob and commit
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T12:38:25.333512+01:00\""
closed-at: "2026-02-06T12:49:08.397533+01:00"
close-reason: validated suite21 + commit 9f96c628
blocks:
  - pez-add-glob-regression-5e67b221
---

Context: zig build test, compare_driver, compare_suite; cause: need verified parity and committed fix; fix: run tests + glob compare + suite delta, then jj describe + jj new; deps: pez-add-glob-regression-5e67b221; verification: glob exact and commit recorded
