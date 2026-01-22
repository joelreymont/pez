---
title: for prelude get_iter
status: open
priority: 2
issue-type: task
created-at: "2026-01-23T13:14:13.258259+02:00"
---

src/decompile.zig:13432 root cause: emitForPrelude stops at first GET_ITER, so listcomp call+STORE_FAST in setup block is skipped when setup contains a listcomp before loop (aioice/ice Connection.gather_candidates), dropping coros assignment and losing cellvars. fix: use last GET_ITER/FOR_LOOP as prelude cut so setup emits listcomp/assign before loop. why: preserve comprehension and closure semantics.
