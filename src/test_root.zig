//! Test root for pez decompiler.
//!
//! This file imports all modules for testing.

const std = @import("std");

// Core modules
pub const pyc = @import("pyc.zig");
pub const opcodes = @import("opcodes.zig");

// Utilities
pub const quickcheck = @import("util/quickcheck.zig");

// Run all tests from imported modules
comptime {
    _ = pyc;
    _ = opcodes;
    _ = quickcheck;
}

test "pez test root" {
    // Placeholder test to ensure test root compiles
    try std.testing.expect(true);
}
