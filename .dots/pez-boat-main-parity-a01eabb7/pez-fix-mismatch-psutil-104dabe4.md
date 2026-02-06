---
title: Fix mismatch psutil/_pslinux
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"\\\\\\\"2026-02-06T14:01:10.262429+01:00\\\\\\\"\\\"\""
closed-at: "2026-02-06T23:10:15.139013+01:00"
close-reason: psutil/_pslinux.pyc is exact in /tmp/pez-boatmain-suite-next6; fix was committed and is in master
---

Context: /tmp/pez-boatmain-suite25 compare report shows psutil/_pslinux.pyc min_semantic_score=0.0; cause TBD via compare_driver+locate_mismatch; fix root-control-flow divergence and add regression fixture+snapshot; proof: compare_driver exact + zig build test
