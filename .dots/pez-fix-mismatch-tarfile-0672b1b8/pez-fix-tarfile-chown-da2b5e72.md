---
title: Fix tarfile chown divergence
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-05T23:36:28.133964+01:00\\\"\""
closed-at: "2026-02-05T23:42:46.329017+01:00"
close-reason: implemented in 43998f3a; compare_driver exact for TarFile.chown/gettarinfo/__exit__; zig build test passed
---

Context: /tmp/pez-tarfile-driver-now-full.json shows <module>.TarFile.chown sem=0.6212; cause TBD; fix: locate mismatch + root-cause patch + compare exact; verification: compare_driver TarFile.chown exact + zig build test
