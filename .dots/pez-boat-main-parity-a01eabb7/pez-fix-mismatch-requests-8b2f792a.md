---
title: Fix mismatch requests/utils
status: open
priority: 1
issue-type: task
created-at: "2026-02-07T01:23:50.551691+01:00"
---

Full context: boat_main suite next22 still reports requests/utils.pyc mismatch (min_sem=0.2614, min_seq=0.8387). Cause: remaining divergences in parse_list_header/parse_dict_header/rewind_body and related control-flow lowering. Fix: use compare_driver + locate_mismatch + targeted AST rewrites with regression tests. Proof: requests/utils compare_driver exact and suite mismatch decrement.
