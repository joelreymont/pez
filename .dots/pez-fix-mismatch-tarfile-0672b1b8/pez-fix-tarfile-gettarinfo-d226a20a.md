---
title: Fix tarfile gettarinfo divergence
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-05T23:03:44.210492+01:00\\\"\""
closed-at: "2026-02-05T23:36:04.972969+01:00"
close-reason: implemented, verified with compare_driver + zig build test, committed 8184e28c
---

Context: /tmp/pez-tarfile-driver-after-whilehead.json shows <module>.TarFile.gettarinfo sem=0.6200; cause TBD at first opcode mismatch; fix: locate mismatch + stage trace + decompiler root-cause patch; deps: tarfile while-head parity done; verification: compare_driver gettarinfo exact + zig build test
