//! Test root for pez decompiler.
//!
//! This file imports all modules for testing.

const std = @import("std");

// Core modules
pub const pyc = @import("pyc.zig");
pub const opcodes = @import("opcodes.zig");
pub const decoder = @import("decoder.zig");
pub const cfg = @import("cfg.zig");
pub const ctrl = @import("ctrl.zig");
pub const dom = @import("dom.zig");
pub const ast = @import("ast.zig");
pub const stack = @import("stack.zig");
pub const codegen = @import("codegen.zig");
pub const decompile = @import("decompile.zig");
pub const snapshot_tests = @import("snapshot_tests.zig");
pub const ternary_boolop_tests = @import("ternary_boolop_tests.zig");
pub const list_extend_tests = @import("list_extend_tests.zig");
pub const test_match_multiblock = @import("test_match_multiblock.zig");
pub const test_match_guards_snapshot = @import("test_match_guards_snapshot.zig");
pub const test_with_legacy_snapshot = @import("test_with_legacy_snapshot.zig");
pub const test_kw_defaults_snapshot = @import("test_kw_defaults_snapshot.zig");
pub const test_boat_main_regressions_snapshot = @import("test_boat_main_regressions_snapshot.zig");
pub const stack_flow_tests = @import("stack_flow_tests.zig");

// Property testing
pub const zcheck = @import("zcheck");

// Property tests
pub const property_tests = @import("property_tests.zig");

// Run all tests from imported modules
comptime {
    _ = pyc;
    _ = opcodes;
    _ = decoder;
    _ = cfg;
    _ = ctrl;
    _ = dom;
    _ = ast;
    _ = stack;
    _ = codegen;
    _ = decompile;
    _ = property_tests;
    _ = snapshot_tests;
    _ = ternary_boolop_tests;
    _ = list_extend_tests;
    _ = test_match_multiblock;
    _ = test_match_guards_snapshot;
    _ = test_with_legacy_snapshot;
    _ = test_kw_defaults_snapshot;
    _ = test_boat_main_regressions_snapshot;
    _ = stack_flow_tests;
}

test "pez test root" {
    // Placeholder test to ensure test root compiles
    try std.testing.expect(true);
}
