---
title: Fix tarfile next divergence
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-05T23:43:06.635922+01:00\\\"\""
closed-at: "2026-02-05T23:55:32.078816+01:00"
close-reason: implemented + committed in f49d87ce; TarFile.next exact
---

Context: /tmp/pez-tarfile-driver-after-chownfix.json shows <module>.TarFile.next sem=0.6933; cause TBD at first opcode mismatch; fix: locate mismatch + root-cause patch + compare exact; verification: compare_driver TarFile.next exact + zig build test
