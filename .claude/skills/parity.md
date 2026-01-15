# Parity Verification and Implementation

Verify decompiler parity gaps and implement fixes to reach 100% output correctness.

## Usage

User says: "parity", "check parity", "get to parity", or "100% parity"

## Instructions

1. **Verify Current State**
   - Run verification agent to identify all gaps
   - Compare pez output vs pycdc on test suite
   - Categorize issues: P0 (hard failures), P1 (wrong output), P2 (cosmetic)

2. **Create Dots for Each Issue**
   - One dot per distinct root cause
   - Format: `dot add "P0/P1: Issue title" -d "Files affected, root cause at file:line, expected fix"`
   - Priority order: P0 → P1 → P2

3. **Implement Fixes**
   - Work P0 issues first (hard failures, memory leaks)
   - Then P1 issues (semantic errors)
   - Skip P2 (cosmetic) unless user requests
   - Test each fix immediately with affected files
   - Close dot when verified working

4. **Verification Loop**
   - After each fix: re-run test suite
   - Identify any new issues or regressions
   - Repeat until P0+P1 gaps = 0

## Success Criteria

- Zero hard failures on all 190 test files
- Zero semantic errors (wrong decompiled output)
- All P0 and P1 dots closed
- Cosmetic differences (P2) acceptable

## Reference

- Parity spec: `~/.claude/plans/bright-kindling-plum.md`
- Test suite: `refs/pycdc/tests/compiled/*.pyc`
- Verification command: `for f in refs/pycdc/tests/compiled/*.pyc; do ./zig-out/bin/pez "$f" 2>&1; done`
