## CODE REVIEW REPORT

### CRITICAL
1. Error masking in decompile simulation helpers
- File: src/decompile.zig:1727-1902
- Type: Anti-pattern | Correctness
- Description: simulateTernaryBranch/Condition/Value/BoolOp and initCondSim use `catch return null`, masking SimError and forcing pattern failure.
- Impact: incorrect output and hidden bugs; violates error policy.
- Recommendation: propagate errors with `try`, return null only for semantic no-match.

2. Error masking in guard/match extraction
- File: src/decompile.zig:4583-4673, 4693-4707
- Type: Anti-pattern | Correctness
- Description: guardExprFromBlock/guardStartInBlock use `catch break/null` and `catch return null` for simulate/makeName.
- Impact: guard expressions silently dropped; match guards decompile incorrectly.
- Recommendation: return error union and propagate with `try`.

3. Error masking in match-literal helpers and kw defaults
- File: src/decompile.zig:5045-5065, 5163, 8727
- Type: Anti-pattern | Correctness
- Description: keyExprsFromObj/attrNamesFromObj/kw defaults paths use `catch return null`.
- Impact: match literals and defaults vanish silently.
- Recommendation: propagate errors; update callers.

4. Error masking in property tests
- File: src/property_tests.zig:156-208, 392-419
- Type: Anti-pattern | Test integrity
- Description: `catch return true/false`, `catch {}` and `catch unreachable` in property tests.
- Impact: hides failing cases; violates error policy.
- Recommendation: handle error unions explicitly without catch-return; treat errors as failures; use `try` where possible.

### HIGH
1. Stack merge compares expr pointers only
- File: src/decompile.zig:419-455
- Type: Correctness | Dataflow precision
- Description: stackValueEqual uses pointer equality for `.expr`.
- Impact: identical expressions from different paths merge to unknown, degrading decompile accuracy.
- Recommendation: implement structural expr equality (ast.exprEqual) and use in stack merges + sameExpr.

2. Stack-flow analysis allocates/clones aggressively
- File: src/decompile.zig:564-642, src/stack.zig:323-335, 923-950
- Type: Performance
- Description: initStackFlow deep clones stack values per block and deinit deep-frees.
- Impact: heavy allocations and timeouts on large bytecode.
- Recommendation: finalize flow_mode shallow deinit + flow clone path; verify with tests.

### MEDIUM
1. Version tests compare structs directly
- File: src/pycdc_tests.zig:31-35, src/test_harness.zig:421-422
- Type: Test policy
- Description: `expectEqual` on struct Version.
- Impact: violates test rules; fragile comparisons.
- Recommendation: compare fields or use ohsnap snapshots.

2. Missing kw-only defaults regression coverage
- File: test/corpus_src/kw_defaults.py, src/test_kw_defaults_snapshot.zig
- Type: Test coverage
- Description: kw-only defaults mapping lacks snapshot coverage.
- Impact: regressions undetected.
- Recommendation: add corpus + snapshot.

### SUMMARY
- Total issues: 8 (Critical: 4, High: 2, Medium: 2, Low: 0)
- Oracle: skipped per request
