---
title: Fix platform remaining mismatches
status: active
priority: 1
issue-type: task
created-at: "\"2026-02-07T10:07:51.982277+01:00\""
---

Files: src/decompile.zig + /tmp/pez-platform-after3.json; cause: platform.pyc still close due architecture/uname CFG divergence; fix: isolate first opcode mismatch per path with compare_driver/locate_mismatch, apply structural rewrite, add regression snapshot; proof: platform mismatches drop and suite counts improve.
