---
title: Fix xdis pyc load errors
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T15:58:10.712443+02:00\\\"\""
closed-at: "2026-01-17T16:12:34.061800+02:00"
close-reason: completed
---

Full context: tools/compare/compare.py + compare runner. xdis in /private/tmp/uncompyle6-venv312 fails to load PYZ-00.pyz_extracted/_pydecimal.pyc, plistlib.pyc, uuid.pyc with struct.error; need xdis on Python 3.9 and use that interpreter in compare runs.
