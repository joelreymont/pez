---
title: Fix mismatch charset cd listcomp
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-07T03:05:52.996951+01:00\""
closed-at: "2026-02-07T03:28:25.698416+01:00"
close-reason: completed in jj 8287412b
---

File: /Users/joel/Work/Shakhed/boat_main_extracted_3.9/PYZ-00.pyz_extracted/charset_normalizer/cd.pyc; cause: missing <module>.alphabet_languages.<listcomp> and min_semantic_score=0.35 in /tmp/pez-boatmain-suite34/pez_compare.json; fix: locate and patch root pass/codegen; proof: compare_driver exact + zig build test
