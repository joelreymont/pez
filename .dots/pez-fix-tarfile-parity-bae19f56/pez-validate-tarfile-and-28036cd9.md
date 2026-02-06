---
title: Validate tarfile and commit
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T13:06:26.153907+01:00\""
closed-at: "2026-02-06T13:23:22.385109+01:00"
close-reason: implemented
blocks:
  - pez-add-tarfile-regression-602b4ec2
---

Context: zig build test + compare_driver + compare_suite; cause: verify and land tarfile parity fix; fix: run validations and commit with jj; deps: pez-add-tarfile-regression-602b4ec2; verification: tarfile exact and suite delta
