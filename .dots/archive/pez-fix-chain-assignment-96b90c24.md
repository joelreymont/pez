---
title: Fix chain assignment decompilation
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-12T06:35:17.196383+02:00\""
closed-at: "2026-01-12T06:45:43.818908+02:00"
---

a = b = c = x becomes a = x; b = x; c = x instead of a = b = c = x. Need to detect DUP_TOP pattern before multiple stores.
