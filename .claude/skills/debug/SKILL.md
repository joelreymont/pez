# Debugging Skill

## When to Use

Activate when user:
- Has a bug to investigate
- Sees wrong output
- Encounters compiler/VM issues
- Needs to trace through pipeline stages
- Mentions "wrong output" or "mismatch"

## First: Identify Abstraction Level

**Generation bug or Execution bug?**

| Symptom | Bug Location |
|---------|--------------|
| Wrong opcode in bytecode | Compiler (generation) |
| Correct bytecode, wrong output | VM (execution) |
| Wrong offset in data | Compiler (data building) |
| Correct offset, wrong data read | VM (parsing) |

**Don't debug execution if bytecode is wrong.**

## Debug Output Strategy

```zig
// BAD: Only print final result
std.debug.print("abs_offset={}\n", .{abs_offset});

// GOOD: Print all components
std.debug.print("bytecode_offset={}, base={x}, abs={}\n",
    .{bytecode_offset, bytecode_base, abs_offset});
```

Batch debug prints. Add multiple in one edit. Target specific data.

## Critical Rules

1. **Never trust stale data** - re-verify after any code change
2. **Print ALL intermediate values** - not just final result
3. **Pick ONE approach** - don't mix hex dumps with runtime prints
4. **Verify assumptions immediately** - add print when you assume a value

## Red Flags (Phantom Bugs)

- "Offset should be X but it's X+26" - Did you regenerate?
- "This worked before" - What changed? Regenerate.
- Comparing hex dump to runtime output - Same build?

## Cleanup

- Remove all debug prints before committing
- Use `zig build -Doptimize=ReleaseFast` for faster debug runs
