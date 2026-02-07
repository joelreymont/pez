---
title: Fix mismatch piexif load
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-07T02:59:11.705206+01:00\""
closed-at: "2026-02-07T03:05:33.643864+01:00"
close-reason: completed in jj 6941dc865de2
---

File: /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/piexif/_load.pyc; cause: compare mismatch min_semantic_score=0.44 with 1 missing unit in /tmp/pez-boatmain-suite33/pez_compare.json; fix: locate divergence and patch decompile pass with test; proof: compare_driver exact + zig build test
