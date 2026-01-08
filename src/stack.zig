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

            .LOAD_SMALL_INT => {
                // LOAD_SMALL_INT n - push small integer directly from arg
                const expr = try ast.makeConstant(self.allocator, .{ .int = @intCast(inst.arg) });
                try self.stack.push(.{ .expr = expr });
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

            .LOAD_FAST_BORROW_LOAD_FAST_BORROW => {
                // Combined instruction that loads two fast variables
                // arg encodes two 4-bit indices: first in high nibble, second in low nibble
                // For arg=0x12: first_idx=1, second_idx=2
                const first_idx = (inst.arg >> 4) & 0xF;
                const second_idx = inst.arg & 0xF;

                // Push first variable
                if (self.getLocal(first_idx)) |name| {
                    const expr = try ast.makeName(self.allocator, name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }

                // Push second variable
                if (self.getLocal(second_idx)) |name| {
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
                ops[0] = cmpOpFromArg(inst.arg, self.version);

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

            .MAKE_FUNCTION => {
                // MAKE_FUNCTION creates a function from a code object on the stack.
                // In Python 3.12+, the code object is on top of stack.
                // The function name comes from the code object's co_qualname.
                //
                // Stack: code_obj -> function
                //
                // For now, we create a placeholder Name expression for the function.
                // Full function decompilation requires recursively processing the code object.
                const code_val = self.stack.pop() orelse return error.StackUnderflow;

                // Try to get the function name from the code object
                // TODO: Extract name from code object's co_qualname when available
                const func_name: []const u8 = "<function>";

                // Create a placeholder Name expression for the function
                const expr = try ast.makeName(self.allocator, func_name, .load);
                try self.stack.push(.{ .expr = expr });

                // Clean up the code value if needed
                if (code_val == .expr) {
                    code_val.expr.deinit(self.allocator);
                    self.allocator.destroy(code_val.expr);
                }
            },

            .SET_FUNCTION_ATTRIBUTE => {
                // SET_FUNCTION_ATTRIBUTE flag - sets closure, defaults, annotations, etc.
                // Stack: func, value -> func
                // The flag in inst.arg determines which attribute to set:
                //   1: defaults
                //   2: kwdefaults
                //   4: annotations
                //   8: closure
                //
                // For now, we just pop the attribute value and keep the function
                if (self.stack.pop()) |attr_val| {
                    var val = attr_val;
                    val.deinit(self.allocator);
                }
                // Function stays on stack (already there from MAKE_FUNCTION)
            },

            .COPY_FREE_VARS => {
                // COPY_FREE_VARS n - copies n free variables for a closure
                // This is a setup instruction, doesn't affect the stack
            },

            .MAKE_CELL => {
                // MAKE_CELL i - creates a cell for a closure variable
                // This is a setup instruction, doesn't affect the stack
            },

            .LOAD_CLOSURE => {
                // LOAD_CLOSURE i - loads a cell/freevar onto the stack
                // For now, push unknown since we don't track cells
                try self.stack.push(.unknown);
            },

            .LOAD_DEREF => {
                // LOAD_DEREF i - loads value from a cell
                // For now, push unknown since we don't track cells
                try self.stack.push(.unknown);
            },

            .STORE_DEREF => {
                // STORE_DEREF i - stores value to a cell
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            // Stack manipulation opcodes
            .DUP_TOP => {
                // DUP_TOP - duplicate top of stack
                const top = self.stack.peek() orelse return error.StackUnderflow;
                if (top == .expr) {
                    // Create a copy of the expression name (for Name exprs) or push unknown
                    // For simplicity, push a reference to the same expression
                    try self.stack.push(top);
                } else {
                    try self.stack.push(top);
                }
            },

            .SWAP => {
                // SWAP i - swap TOS with stack item at position i
                if (inst.arg < 2) return error.InvalidSwapArg;
                const pos = inst.arg - 1;
                if (pos >= self.stack.items.items.len) return error.StackUnderflow;
                const top_idx = self.stack.items.items.len - 1;
                const swap_idx = self.stack.items.items.len - 1 - pos;
                const tmp = self.stack.items.items[top_idx];
                self.stack.items.items[top_idx] = self.stack.items.items[swap_idx];
                self.stack.items.items[swap_idx] = tmp;
            },

            .COPY => {
                // COPY i - copy stack item at position i to TOS
                const pos = inst.arg;
                if (pos < 1 or pos > self.stack.items.items.len) return error.StackUnderflow;
                const copy_idx = self.stack.items.items.len - pos;
                const val = self.stack.items.items[copy_idx];
                try self.stack.push(val);
            },

            // Unary operators
            .UNARY_NEGATIVE => {
                const operand = self.stack.popExpr() orelse return error.StackUnderflow;
                const expr = try ast.makeUnaryOp(self.allocator, .usub, operand);
                try self.stack.push(.{ .expr = expr });
            },

            .UNARY_NOT => {
                const operand = self.stack.popExpr() orelse return error.StackUnderflow;
                const expr = try ast.makeUnaryOp(self.allocator, .not_, operand);
                try self.stack.push(.{ .expr = expr });
            },

            .UNARY_INVERT => {
                const operand = self.stack.popExpr() orelse return error.StackUnderflow;
                const expr = try ast.makeUnaryOp(self.allocator, .invert, operand);
                try self.stack.push(.{ .expr = expr });
            },

            // Iterator opcodes
            .GET_ITER => {
                // GET_ITER - get an iterator from TOS, leave iterator on stack
                // The expression stays on the stack conceptually as an iterator
                // In decompilation, we track what's being iterated over
            },

            .FOR_ITER => {
                // FOR_ITER delta - get next value from iterator
                // On exhaustion, jumps forward by delta
                // For now, just push unknown for the iteration value
                try self.stack.push(.unknown);
            },

            // Import opcodes
            .IMPORT_NAME => {
                // IMPORT_NAME namei - imports module names[namei]
                // Stack: fromlist, level -> module
                _ = self.stack.pop(); // level
                _ = self.stack.pop(); // fromlist
                if (self.getName(inst.arg)) |name| {
                    const expr = try ast.makeName(self.allocator, name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .IMPORT_FROM => {
                // IMPORT_FROM namei - load attribute names[namei] from module on TOS
                // Stack: module -> module, attr
                // Module stays on stack, attr is pushed
                if (self.getName(inst.arg)) |name| {
                    const expr = try ast.makeName(self.allocator, name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            // Attribute access
            .LOAD_ATTR => {
                // LOAD_ATTR namei - replace TOS with TOS.names[namei]
                const obj = self.stack.popExpr() orelse return error.StackUnderflow;
                if (self.getName(inst.arg >> 1)) |attr_name| {
                    const attr = try ast.makeAttribute(self.allocator, obj, attr_name, .load);
                    try self.stack.push(.{ .expr = attr });
                } else {
                    obj.deinit(self.allocator);
                    self.allocator.destroy(obj);
                    try self.stack.push(.unknown);
                }
            },

            .STORE_ATTR => {
                // STORE_ATTR namei - TOS.names[namei] = TOS1
                // Stack: obj, value -> (empty)
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            // Subscript operations
            .BINARY_SUBSCR => {
                // BINARY_SUBSCR - TOS = TOS1[TOS]
                const index = self.stack.popExpr() orelse return error.StackUnderflow;
                const container = self.stack.popExpr() orelse {
                    index.deinit(self.allocator);
                    self.allocator.destroy(index);
                    return error.StackUnderflow;
                };
                const expr = try ast.makeSubscript(self.allocator, container, index, .load);
                try self.stack.push(.{ .expr = expr });
            },

            .STORE_SUBSCR => {
                // STORE_SUBSCR - TOS1[TOS] = TOS2
                // Stack: key, container, value -> (empty)
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            // Dict operations
            .BUILD_MAP => {
                // BUILD_MAP count - create a dict from count key/value pairs
                const count = inst.arg;
                const expr = try self.allocator.create(Expr);

                if (count == 0) {
                    expr.* = .{ .dict = .{ .keys = &.{}, .values = &.{} } };
                } else {
                    const keys = try self.allocator.alloc(?*Expr, count);
                    const values = try self.allocator.alloc(*Expr, count);

                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const val = self.stack.popExpr() orelse {
                            // Clean up already allocated
                            var j: usize = 0;
                            while (j < i) : (j += 1) {
                                if (keys[j]) |k| {
                                    k.deinit(self.allocator);
                                    self.allocator.destroy(k);
                                }
                                values[j].deinit(self.allocator);
                                self.allocator.destroy(values[j]);
                            }
                            self.allocator.free(keys);
                            self.allocator.free(values);
                            self.allocator.destroy(expr);
                            return error.StackUnderflow;
                        };
                        const key = self.stack.popExpr();
                        keys[count - 1 - i] = key;
                        values[count - 1 - i] = val;
                    }
                    expr.* = .{ .dict = .{ .keys = keys, .values = values } };
                }
                try self.stack.push(.{ .expr = expr });
            },

            // Slice operations
            .BUILD_SLICE => {
                // BUILD_SLICE argc - build slice from argc elements
                // argc=2: TOS1:TOS, argc=3: TOS2:TOS1:TOS
                const argc = inst.arg;
                var step: ?*Expr = null;
                if (argc == 3) {
                    step = self.stack.popExpr();
                }
                const stop = self.stack.popExpr();
                const start = self.stack.popExpr();

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .slice = .{
                    .lower = start,
                    .upper = stop,
                    .step = step,
                } };
                try self.stack.push(.{ .expr = expr });
            },

            // Class-related opcodes
            .LOAD_BUILD_CLASS => {
                // LOAD_BUILD_CLASS - push __build_class__ builtin onto stack
                // Used to construct classes: __build_class__(func, name, *bases, **keywords)
                const expr = try ast.makeName(self.allocator, "__build_class__", .load);
                try self.stack.push(.{ .expr = expr });
            },

            .LOAD_CLASSDEREF => {
                // LOAD_CLASSDEREF i - load value from cell or free variable for class scoping
                // Similar to LOAD_DEREF but with special class scope handling
                try self.stack.push(.unknown);
            },

            // Exception handling opcodes
            .PUSH_EXC_INFO => {
                // PUSH_EXC_INFO - pushes exception info onto stack
                // Used when entering except handler, pushes (exc, tb)
                try self.stack.push(.unknown);
            },

            .CHECK_EXC_MATCH => {
                // CHECK_EXC_MATCH - checks if TOS matches TOS1 exception type
                // Pops the exception type, leaves bool result on stack
                _ = self.stack.pop();
                try self.stack.push(.unknown);
            },

            .RERAISE => {
                // RERAISE depth - re-raise the exception
                // Pops nothing new, exception info already on stack
            },

            .SETUP_FINALLY, .POP_EXCEPT => {
                // These are control flow markers, no stack effect
            },

            // Global/name deletion
            .DELETE_NAME, .DELETE_GLOBAL => {
                // DELETE_NAME/GLOBAL namei - deletes names[namei]
                // No stack effect
            },

            .DELETE_FAST => {
                // DELETE_FAST i - deletes local variable
                // No stack effect
            },

            // Format string opcodes
            .FORMAT_VALUE => {
                // FORMAT_VALUE flags - format TOS for f-string
                // flags & 0x03: conversion (0=none, 1=str, 2=repr, 3=ascii)
                // flags & 0x04: format spec on stack
                const has_spec = (inst.arg & 0x04) != 0;
                var format_spec: ?*Expr = null;
                if (has_spec) {
                    format_spec = self.stack.popExpr();
                }

                const value = self.stack.popExpr() orelse {
                    if (format_spec) |spec| {
                        spec.deinit(self.allocator);
                        self.allocator.destroy(spec);
                    }
                    return error.StackUnderflow;
                };

                const conversion: ?u8 = switch (inst.arg & 0x03) {
                    1 => 's', // str
                    2 => 'r', // repr
                    3 => 'a', // ascii
                    else => null,
                };

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .formatted_value = .{
                    .value = value,
                    .conversion = conversion,
                    .format_spec = format_spec,
                } };
                try self.stack.push(.{ .expr = expr });
            },

            .BUILD_STRING => {
                // BUILD_STRING count - build f-string from count pieces
                const count = inst.arg;
                const values = if (count == 0) &[_]*Expr{} else try self.stack.popNExprs(count);

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .joined_str = .{ .values = values } };
                try self.stack.push(.{ .expr = expr });
            },

            // Boolean operations (for short-circuit evaluation)
            .JUMP_IF_TRUE_OR_POP, .JUMP_IF_FALSE_OR_POP => {
                // These leave TOS on stack if condition matches, otherwise pop and jump
                // For simulation, we leave the value on stack (the expr stays)
            },

            // Yield opcodes
            .GET_YIELD_FROM_ITER => {
                // GET_YIELD_FROM_ITER - prepare iterator for yield from
                // TOS is the iterable, result is the iterator
            },

            .YIELD_VALUE => {
                // YIELD_VALUE - yield TOS
                const value = self.stack.popExpr();
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .yield_expr = .{ .value = value } };
                try self.stack.push(.{ .expr = expr });
            },

            .SEND => {
                // SEND delta - send value to generator
                // TOS is the value to send, TOS1 is the generator
                _ = self.stack.pop(); // pop sent value
                // Generator stays, received value pushed
                try self.stack.push(.unknown);
            },

            // Comprehension opcodes
            .LIST_APPEND => {
                // LIST_APPEND i - append TOS to list at stack[i]
                // Used in list comprehensions
                // Stack: ..., list, ..., item -> ..., list, ...
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .SET_ADD => {
                // SET_ADD i - add TOS to set at stack[i]
                // Used in set comprehensions
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .MAP_ADD => {
                // MAP_ADD i - add TOS1:TOS to dict at stack[i]
                // Used in dict comprehensions
                // Stack: ..., dict, ..., key, value -> ..., dict, ...
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .LIST_EXTEND => {
                // LIST_EXTEND i - extend list at stack[i] with TOS
                // Used for [*items] unpacking
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .SET_UPDATE => {
                // SET_UPDATE i - update set at stack[i] with TOS
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .DICT_UPDATE => {
                // DICT_UPDATE i - update dict at stack[i] with TOS
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .DICT_MERGE => {
                // DICT_MERGE i - merge TOS into dict at stack[i]
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            // Await expression
            .GET_AWAITABLE => {
                // GET_AWAITABLE - get awaitable from TOS
                // Leaves awaitable on stack
            },

            .END_ASYNC_FOR => {
                // END_ASYNC_FOR - cleanup after async for loop
            },

            // Unpacking
            .UNPACK_SEQUENCE => {
                // UNPACK_SEQUENCE count - unpack TOS into count values
                const count = inst.arg;
                _ = self.stack.pop();
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    try self.stack.push(.unknown);
                }
            },

            .UNPACK_EX => {
                // UNPACK_EX - unpack with *rest
                // Low byte: before star, high byte: after star
                const before = inst.arg & 0xFF;
                const after = (inst.arg >> 8) & 0xFF;
                _ = self.stack.pop();
                var i: u32 = 0;
                while (i < before + 1 + after) : (i += 1) {
                    try self.stack.push(.unknown);
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
/// In Python 3.13+, comparison type is in bits 5+.
/// In Python 3.12, it's in bits 4+.
/// In earlier versions, it's the raw arg.
fn cmpOpFromArg(arg: u32, ver: Version) ast.CmpOp {
    const cmp: u8 = if (ver.gte(3, 13))
        @truncate(arg >> 5)
    else if (ver.gte(3, 12))
        @truncate(arg >> 4)
    else
        @truncate(arg);

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
