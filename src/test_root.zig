//! Test root for pez decompiler.
//!
//! This file imports all modules for testing.

const std = @import("std");

// Core modules
pub const pyc = @import("pyc.zig");
pub const opcodes = @import("opcodes.zig");
pub const decoder = @import("decoder.zig");
pub const cfg = @import("cfg.zig");

// Utilities
pub const quickcheck = @import("util/quickcheck.zig");

// Run all tests from imported modules
comptime {
    _ = pyc;
    _ = opcodes;
    _ = decoder;
    _ = cfg;
    _ = quickcheck;
}

test "pez test root" {
    // Placeholder test to ensure test root compiles
    try std.testing.expect(true);
}
