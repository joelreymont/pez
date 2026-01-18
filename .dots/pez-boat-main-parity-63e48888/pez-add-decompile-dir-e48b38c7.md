---
title: Add decompile dir runner
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-18T07:27:37.554964+02:00\\\"\""
closed-at: "2026-01-18T07:28:19.415601+02:00"
close-reason: done
---

Full context: need to decompile /Users/joel/Work/Shakhed/boat_main_extracted_3.9/*.pyc to .py files for compare_dir; root cause: pez outputs to stdout only; fix: add tool script to run pez per .pyc and write output to mirror dir; why: enable bytecode compare + parity checks without manual piping.
