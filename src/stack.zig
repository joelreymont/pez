//! Stack simulation for bytecode analysis.
//!
//! Simulates Python's evaluation stack to reconstruct expressions
//! from bytecode instructions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const decoder = @import("decoder.zig");
const opcodes = @import("opcodes.zig");
const pyc = @import("pyc.zig");

pub const Expr = ast.Expr;
pub const Instruction = decoder.Instruction;
pub const Opcode = opcodes.Opcode;
pub const Version = opcodes.Version;

/// A value on the simulated stack.
pub const StackValue = union(enum) {
    /// An AST expression.
    expr: *Expr,
    /// A NULL marker (for PUSH_NULL).
    null_marker,
    /// Unknown/untracked value.
    unknown,

    pub fn deinit(self: StackValue, allocator: Allocator) void {
        switch (self) {
            .expr => |e| {
                e.deinit(allocator);
                allocator.destroy(e);
            },
            else => {},
        }
    }
};

/// Simulated Python evaluation stack.
pub const Stack = struct {
    items: std.ArrayList(StackValue),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Stack {
        return .{
            .items = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Stack) void {
        for (self.items.items) |*item| {
            item.deinit(self.allocator);
        }
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *Stack, value: StackValue) !void {
        try self.items.append(self.allocator, value);
    }

    pub fn pop(self: *Stack) ?StackValue {
        return self.items.pop();
    }

    pub fn popExpr(self: *Stack) ?*Expr {
        const val = self.pop() orelse return null;
        return switch (val) {
            .expr => |e| e,
            else => null,
        };
    }

    pub fn peek(self: *const Stack) ?StackValue {
        if (self.items.items.len == 0) return null;
        return self.items.items[self.items.items.len - 1];
    }

    pub fn len(self: *const Stack) usize {
        return self.items.items.len;
    }

    /// Pop n items and return them in reverse order (bottom to top becomes first to last).
    pub fn popN(self: *Stack, n: usize) ![]StackValue {
        if (n > self.items.items.len) return error.StackUnderflow;
        const result = try self.allocator.alloc(StackValue, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            result[n - 1 - i] = self.items.pop().?;
        }
        return result;
    }

    /// Pop n expressions in reverse order.
    pub fn popNExprs(self: *Stack, n: usize) ![]const *Expr {
        const values = try self.popN(n);
        defer self.allocator.free(values);

        const exprs = try self.allocator.alloc(*Expr, n);
        for (values, 0..) |v, i| {
            exprs[i] = switch (v) {
                .expr => |e| e,
                else => return error.NotAnExpression,
            };
        }
        return exprs;
    }
};

/// Context for stack simulation.
pub const SimContext = struct {
    allocator: Allocator,
    version: Version,
    /// Code object being simulated.
    code: *const pyc.Code,
    /// Current stack state.
    stack: Stack,

    pub fn init(allocator: Allocator, code: *const pyc.Code, version: Version) SimContext {
        return .{
            .allocator = allocator,
            .version = version,
            .code = code,
            .stack = Stack.init(allocator),
        };
    }

    pub fn deinit(self: *SimContext) void {
        self.stack.deinit();
    }

    /// Get a name from the code object's names tuple.
    pub fn getName(self: *const SimContext, idx: u32) ?[]const u8 {
        if (idx < self.code.names.len) {
            return self.code.names[idx];
        }
        return null;
    }

    /// Get a constant from the code object's consts tuple.
    pub fn getConst(self: *const SimContext, idx: u32) ?pyc.Object {
        if (idx < self.code.consts.len) {
            return self.code.consts[idx];
        }
        return null;
    }

    /// Get a local variable name.
    pub fn getLocal(self: *const SimContext, idx: u32) ?[]const u8 {
        if (idx < self.code.varnames.len) {
            return self.code.varnames[idx];
        }
        return null;
    }

    /// Convert a pyc.Object constant to an AST Constant.
    pub fn objToConstant(self: *SimContext, obj: pyc.Object) !ast.Constant {
        _ = self;
        return switch (obj) {
            .none => .none,
            .true_val => .true_,
            .false_val => .false_,
            .ellipsis => .ellipsis,
            .int => |v| switch (v) {
                .small => |s| .{ .int = s },
                .big => .{ .int = 0 }, // TODO: handle big ints
            },
            .float => |v| .{ .float = v },
            .complex => |v| .{ .complex = .{ .real = v.real, .imag = v.imag } },
            .string => |s| .{ .string = s },
            .bytes => |b| .{ .bytes = b },
            else => .none, // TODO: handle tuples, code objects, etc.
        };
    }

    /// Simulate a single instruction.
    pub fn simulate(self: *SimContext, inst: Instruction) !void {
        switch (inst.opcode) {
            .NOP, .RESUME, .CACHE, .EXTENDED_ARG => {
                // No stack effect
            },

            .POP_TOP => {
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .PUSH_NULL => {
                try self.stack.push(.null_marker);
            },

            .LOAD_CONST => {
                if (self.getConst(inst.arg)) |obj| {
                    const constant = try self.objToConstant(obj);
                    const expr = try ast.makeConstant(self.allocator, constant);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .LOAD_NAME, .LOAD_GLOBAL => {
                if (self.getName(if (inst.opcode == .LOAD_GLOBAL) inst.arg >> 1 else inst.arg)) |name| {
                    const expr = try ast.makeName(self.allocator, name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .LOAD_FAST, .LOAD_FAST_CHECK, .LOAD_FAST_BORROW => {
                if (self.getLocal(inst.arg)) |name| {
                    const expr = try ast.makeName(self.allocator, name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .STORE_NAME, .STORE_GLOBAL => {
                // Pop the value and create assignment
                // For now, just pop the value
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .STORE_FAST => {
                // Pop the value
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .BINARY_OP => {
                // Pop two operands, create BinOp expression
                const right = self.stack.popExpr() orelse return error.StackUnderflow;
                const left = self.stack.popExpr() orelse {
                    right.deinit(self.allocator);
                    self.allocator.destroy(right);
                    return error.StackUnderflow;
                };

                const op = binOpFromArg(inst.arg);
                const expr = try ast.makeBinOp(self.allocator, left, op, right);
                try self.stack.push(.{ .expr = expr });
            },

            .COMPARE_OP => {
                // Pop two operands, create Compare expression
                const right = self.stack.popExpr() orelse return error.StackUnderflow;
                const left = self.stack.popExpr() orelse {
                    right.deinit(self.allocator);
                    self.allocator.destroy(right);
                    return error.StackUnderflow;
                };

                // Create a compare expression
                const comparators = try self.allocator.alloc(*Expr, 1);
                comparators[0] = right;
                const ops = try self.allocator.alloc(ast.CmpOp, 1);
                ops[0] = cmpOpFromArg(inst.arg);

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .compare = .{
                    .left = left,
                    .ops = ops,
                    .comparators = comparators,
                } };
                try self.stack.push(.{ .expr = expr });
            },

            .BUILD_LIST => {
                const count = inst.arg;
                if (count == 0) {
                    const expr = try ast.makeList(self.allocator, &.{}, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    const elts = try self.stack.popNExprs(count);
                    const expr = try ast.makeList(self.allocator, elts, .load);
                    try self.stack.push(.{ .expr = expr });
                }
            },

            .BUILD_TUPLE => {
                const count = inst.arg;
                if (count == 0) {
                    const expr = try ast.makeTuple(self.allocator, &.{}, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    const elts = try self.stack.popNExprs(count);
                    const expr = try ast.makeTuple(self.allocator, elts, .load);
                    try self.stack.push(.{ .expr = expr });
                }
            },

            .BUILD_SET => {
                const count = inst.arg;
                const elts = if (count == 0) &[_]*Expr{} else try self.stack.popNExprs(count);
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .set = .{ .elts = elts } };
                try self.stack.push(.{ .expr = expr });
            },

            .CALL => {
                // In 3.12+: CALL argc
                // Stack: callable, NULL, arg0, ..., argN -> result
                // Pop argc args, then NULL marker (if present), then callable
                const argc = inst.arg;
                const args = try self.stack.popNExprs(argc);

                // Check for NULL marker (PUSH_NULL before function)
                const maybe_null = self.stack.pop();
                var func_val: StackValue = undefined;
                if (maybe_null) |val| {
                    if (val == .null_marker) {
                        // Pop the actual function
                        func_val = self.stack.pop() orelse return error.StackUnderflow;
                    } else {
                        // Not a NULL marker, this is the function
                        func_val = val;
                    }
                } else {
                    return error.StackUnderflow;
                }

                const func = switch (func_val) {
                    .expr => |e| e,
                    else => {
                        self.allocator.free(args);
                        return error.NotAnExpression;
                    },
                };

                const expr = try ast.makeCall(self.allocator, func, args);
                try self.stack.push(.{ .expr = expr });
            },

            .RETURN_VALUE => {
                // Pop return value - typically ends simulation
                _ = self.stack.pop();
            },

            .RETURN_CONST => {
                // Push constant then "return" it
                if (self.getConst(inst.arg)) |obj| {
                    const constant = try self.objToConstant(obj);
                    const expr = try ast.makeConstant(self.allocator, constant);
                    try self.stack.push(.{ .expr = expr });
                }
            },

            else => {
                // Unhandled opcode - push unknown for each value it would produce
                // For now, just push unknown
                try self.stack.push(.unknown);
            },
        }
    }
};

/// Convert BINARY_OP arg to BinOp enum.
fn binOpFromArg(arg: u32) ast.BinOp {
    return switch (arg) {
        0 => .add,
        1 => .bitand,
        2 => .floordiv,
        3 => .lshift,
        4 => .matmult,
        5 => .mult,
        6 => .mod,
        7 => .bitor,
        8 => .pow,
        9 => .rshift,
        10 => .sub,
        11 => .div,
        12 => .bitxor,
        // Inplace variants (13-25) map to the same operations
        13 => .add,
        14 => .bitand,
        15 => .floordiv,
        16 => .lshift,
        17 => .matmult,
        18 => .mult,
        19 => .mod,
        20 => .bitor,
        21 => .pow,
        22 => .rshift,
        23 => .sub,
        24 => .div,
        25 => .bitxor,
        else => .add,
    };
}

/// Convert COMPARE_OP arg to CmpOp enum.
fn cmpOpFromArg(arg: u32) ast.CmpOp {
    // The arg encodes the comparison in the low bits
    const cmp = arg & 0xF;
    return switch (cmp) {
        0 => .lt,
        1 => .lte,
        2 => .eq,
        3 => .not_eq,
        4 => .gt,
        5 => .gte,
        else => .eq,
    };
}

test "stack simulation load const" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a minimal code object
    var consts = [_]pyc.Object{
        .{ .int = pyc.Int.fromI64(42) },
    };
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(3, 12);

    var ctx = SimContext.init(allocator, &code, version);
    defer ctx.deinit();

    // Simulate LOAD_CONST 0
    const inst = Instruction{
        .opcode = .LOAD_CONST,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 1), ctx.stack.len());
    const val = ctx.stack.peek().?;
    try testing.expect(val == .expr);
    try testing.expect(val.expr.constant == .int);
    try testing.expectEqual(@as(i64, 42), val.expr.constant.int);
}
