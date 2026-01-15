---
title: Debug Python 2.2 marshal read sequence
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-15T18:10:32.225836+02:00\\\"\""
closed-at: "2026-01-15T18:12:46.056548+02:00"
close-reason: marshal parsing fixed, but bytecode decoding broken for Python 2.2
blocks:
  - pez-fix-python-1-43689e72
---

Trace byte-by-byte what readCode reads for test_class.2.2.pyc.
Add debug prints to see positions after each field read.
Verify 16-bit fields are being read at correct offsets.
File: src/pyc.zig:874-889
