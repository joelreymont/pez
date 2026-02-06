---
title: Repro tarfile add mismatch
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-06T13:06:07.939530+01:00\""
closed-at: "2026-02-06T13:23:22.374224+01:00"
close-reason: implemented
---

Context: tools/compare/compare_driver.py; cause: isolate TarFile.add non-exact; fix: run compare_driver + locate_mismatch output to /tmp/tarfile-*.json; deps: none; verification: mismatch path <module>.TarFile.add
