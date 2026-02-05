//! Stack simulation for bytecode analysis.
//!
//! Simulates Python's evaluation stack to reconstruct expressions
//! from bytecode instructions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const codegen = @import("codegen.zig");
const decoder = @import("decoder.zig");
const name_mangle = @import("name_mangle.zig");
const opcodes = @import("opcodes.zig");
const pyc = @import("pyc.zig");
const signature = @import("signature.zig");

pub const Expr = ast.Expr;
pub const Instruction = decoder.Instruction;
pub const Opcode = opcodes.Opcode;
pub const Version = opcodes.Version;

pub const SimError = Allocator.Error || error{
    StackUnderflow,
    NotAnExpression,
    InvalidSwapArg,
    InvalidDupArg,
    InvalidComprehension,
    InvalidConstant,
    InvalidLambdaBody,
    InvalidKeywordNames,
    InvalidStackDepth,
    InvalidTernary,
    UnsupportedConstant,
    InvalidConstKeyMap,
};

pub const FunctionValue = struct {
    code: *const pyc.Code,
    decorators: std.ArrayListUnmanaged(*Expr),
    defaults: []const *Expr = &.{},
    kw_defaults: []const ?*Expr = &.{},
    annotations: []const signature.Annotation = &.{},

    pub fn deinit(self: *FunctionValue, allocator: Allocator) void {
        // Arena-allocated, no cleanup needed
        _ = self;
        _ = allocator;
    }
};

pub const ClassValue = struct {
    code: *const pyc.Code,
    name: []const u8,
    bases: []const *Expr,
    keywords: []const ast.Keyword,
    decorators: std.ArrayListUnmanaged(*Expr),

    pub fn deinit(self: *ClassValue, allocator: Allocator) void {
        // Arena-allocated, no cleanup needed
        _ = self;
        _ = allocator;
    }
};

const CompKind = enum {
    list,
    set,
    dict,
    genexpr,
};

const CompObject = struct {
    code: *const pyc.Code,
    kind: CompKind,
};

const PendingComp = struct {
    target: ?*Expr,
    iter: ?*Expr,
    ifs: std.ArrayListUnmanaged(*Expr),
    is_async: bool,

    fn deinit(self: *PendingComp, ast_alloc: Allocator, stack_alloc: Allocator) void {
        if (self.target) |target| {
            target.deinit(ast_alloc);
            ast_alloc.destroy(target);
        }
        if (self.iter) |iter_expr| {
            iter_expr.deinit(ast_alloc);
            ast_alloc.destroy(iter_expr);
        }
        for (self.ifs.items) |cond| {
            cond.deinit(ast_alloc);
            ast_alloc.destroy(cond);
        }
        self.ifs.deinit(stack_alloc);
    }
};

const PendingUnpack = struct {
    builder: *CompBuilder,
    remain: u32,
    names: std.ArrayListUnmanaged(*Expr),

    fn deinit(self: *PendingUnpack, ast_alloc: Allocator, stack_alloc: Allocator) void {
        for (self.names.items) |expr| {
            expr.deinit(ast_alloc);
            ast_alloc.destroy(expr);
        }
        self.names.deinit(stack_alloc);
    }
};

const CompBuilder = struct {
    kind: CompKind,
    generators: std.ArrayListUnmanaged(PendingComp),
    loop_stack: std.ArrayListUnmanaged(usize),
    elt: ?*Expr,
    key: ?*Expr,
    value: ?*Expr,
    seen_append: bool,

    fn init(kind: CompKind) CompBuilder {
        return .{
            .kind = kind,
            .generators = .{},
            .loop_stack = .{},
            .elt = null,
            .key = null,
            .value = null,
            .seen_append = false,
        };
    }

    fn deinit(self: *CompBuilder, ast_alloc: Allocator, stack_alloc: Allocator) void {
        for (self.generators.items) |*gen| {
            gen.deinit(ast_alloc, stack_alloc);
        }
        self.generators.deinit(stack_alloc);
        self.loop_stack.deinit(stack_alloc);
        stack_alloc.destroy(self);
    }
};

/// Import module tracker.
pub const ImportModule = struct {
    module: []const u8,
    fromlist: []const []const u8,
    level: u32,
};

/// A value on the simulated stack.
pub const StackValue = union(enum) {
    /// An AST expression.
    expr: *Expr,
    /// A function object with code and decorators.
    function_obj: *FunctionValue,
    /// A class object with code, bases, and decorators.
    class_obj: *ClassValue,
    /// A comprehension builder for inline comprehensions.
    comp_builder: *CompBuilder,
    /// A comprehension code object (list/set/dict/genexpr).
    comp_obj: CompObject,
    /// A code object constant (non-owning).
    code_obj: *const pyc.Code,
    /// An import module (for IMPORT_NAME).
    import_module: ImportModule,
    /// A NULL marker (for PUSH_NULL).
    null_marker,
    /// A saved local (for LOAD_FAST_AND_CLEAR).
    saved_local: []const u8,
    /// A type alias (name, value) for PEP 695.
    type_alias: *Expr,
    /// Exception placeholder for handler stacks.
    exc_marker,
    /// Unknown/untracked value.
    unknown,

    pub fn deinit(self: StackValue, ast_alloc: Allocator, stack_alloc: Allocator) void {
        switch (self) {
            .expr => {
                // Expr nodes are arena-owned; avoid deep deinit to prevent shared-node corruption.
            },
            .comp_builder => |b| {
                b.deinit(ast_alloc, stack_alloc);
            },
            .type_alias => |e| {
                if (e.* == .tuple) {
                    if (e.tuple.elts.len > 0) ast_alloc.free(e.tuple.elts);
                    ast_alloc.destroy(e);
                } else {
                    e.deinit(ast_alloc);
                    ast_alloc.destroy(e);
                }
            },
            .exc_marker => {},
            // function_obj and class_obj are consumed by decompiler and ownership transfers
            // to arena or they're cleaned up explicitly by the code that creates them
            else => {},
        }
    }
};

pub fn stackValueEqual(a: StackValue, b: StackValue) bool {
    return switch (a) {
        .expr => |ae| switch (b) {
            .expr => |be| ast.exprEqual(ae, be),
            else => false,
        },
        .function_obj => |af| switch (b) {
            .function_obj => |bf| functionValueEqual(af, bf),
            else => false,
        },
        .class_obj => |ac| switch (b) {
            .class_obj => |bc| classValueEqual(ac, bc),
            else => false,
        },
        .comp_builder => |ab| switch (b) {
            .comp_builder => |bb| compBuilderEqual(ab, bb),
            else => false,
        },
        .comp_obj => |aco| switch (b) {
            .comp_obj => |bco| aco.code == bco.code and aco.kind == bco.kind,
            else => false,
        },
        .code_obj => |acode| switch (b) {
            .code_obj => |bcode| acode == bcode,
            else => false,
        },
        .import_module => |aimp| switch (b) {
            .import_module => |bimp| blk: {
                if (!std.mem.eql(u8, aimp.module, bimp.module)) break :blk false;
                if (aimp.level != bimp.level) break :blk false;
                if (aimp.fromlist.len != bimp.fromlist.len) break :blk false;
                for (aimp.fromlist, 0..) |name, idx| {
                    if (!std.mem.eql(u8, name, bimp.fromlist[idx])) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .null_marker => switch (b) {
            .null_marker => true,
            else => false,
        },
        .saved_local => |name| switch (b) {
            .saved_local => |other| std.mem.eql(u8, name, other),
            else => false,
        },
        .type_alias => |ae| switch (b) {
            .type_alias => |be| ast.exprEqual(ae, be),
            else => false,
        },
        .exc_marker => switch (b) {
            .exc_marker => true,
            else => false,
        },
        .unknown => switch (b) {
            .unknown => true,
            else => false,
        },
    };
}

fn isExcPh(val: StackValue) bool {
    return switch (val) {
        .exc_marker => true,
        .expr => |e| switch (e.*) {
            .name => |n| std.mem.eql(u8, n.id, "__exception__"),
            else => false,
        },
        else => false,
    };
}

fn exprSliceEqual(a: []const *Expr, b: []const *Expr) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |ae, idx| {
        if (!ast.exprEqual(ae, b[idx])) return false;
    }
    return true;
}

fn optExprSliceEqual(a: []const ?*Expr, b: []const ?*Expr) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |ae, idx| {
        const be = b[idx];
        if (ae == null or be == null) {
            if (ae != null or be != null) return false;
            continue;
        }
        if (!ast.exprEqual(ae.?, be.?)) return false;
    }
    return true;
}

fn annotationsEqual(a: []const signature.Annotation, b: []const signature.Annotation) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |ann, idx| {
        const other = b[idx];
        if (!std.mem.eql(u8, ann.name, other.name)) return false;
        if (!ast.exprEqual(ann.value, other.value)) return false;
    }
    return true;
}

fn functionValueEqual(a: *const FunctionValue, b: *const FunctionValue) bool {
    if (a.code != b.code) return false;
    if (!exprSliceEqual(a.defaults, b.defaults)) return false;
    if (!optExprSliceEqual(a.kw_defaults, b.kw_defaults)) return false;
    if (!exprSliceEqual(a.decorators.items, b.decorators.items)) return false;
    if (!annotationsEqual(a.annotations, b.annotations)) return false;
    return true;
}

fn keywordsEqual(a: []const ast.Keyword, b: []const ast.Keyword) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |kw, idx| {
        const other = b[idx];
        if (kw.arg == null and other.arg != null) return false;
        if (kw.arg != null and other.arg == null) return false;
        if (kw.arg) |arg| {
            if (!std.mem.eql(u8, arg, other.arg.?)) return false;
        }
        if (!ast.exprEqual(kw.value, other.value)) return false;
    }
    return true;
}

fn classValueEqual(a: *const ClassValue, b: *const ClassValue) bool {
    if (a.code != b.code) return false;
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (!exprSliceEqual(a.bases, b.bases)) return false;
    if (!keywordsEqual(a.keywords, b.keywords)) return false;
    if (!exprSliceEqual(a.decorators.items, b.decorators.items)) return false;
    return true;
}

fn compBuilderEqual(a: *const CompBuilder, b: *const CompBuilder) bool {
    if (a.kind != b.kind) return false;
    if (a.seen_append != b.seen_append) return false;
    if (!optExprEqual(a.elt, b.elt)) return false;
    if (!optExprEqual(a.key, b.key)) return false;
    if (!optExprEqual(a.value, b.value)) return false;
    if (a.generators.items.len != b.generators.items.len) return false;
    for (a.generators.items, 0..) |gen, idx| {
        if (!pendingCompEqual(gen, b.generators.items[idx])) return false;
    }
    if (a.loop_stack.items.len != b.loop_stack.items.len) return false;
    for (a.loop_stack.items, 0..) |idx_val, idx| {
        if (idx_val != b.loop_stack.items[idx]) return false;
    }
    return true;
}

fn pendingCompEqual(a: PendingComp, b: PendingComp) bool {
    if (a.is_async != b.is_async) return false;
    if (!optExprEqual(a.target, b.target)) return false;
    if (!optExprEqual(a.iter, b.iter)) return false;
    if (!exprSliceEqual(a.ifs.items, b.ifs.items)) return false;
    return true;
}

fn optExprEqual(a: ?*Expr, b: ?*Expr) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return ast.exprEqual(a.?, b.?);
}

/// Simulated Python evaluation stack.
pub const Stack = struct {
    items: std.ArrayListUnmanaged(StackValue),
    stack_alloc: Allocator,
    ast_alloc: Allocator,
    allow_underflow: bool = false,
    pop_scratch: std.ArrayListUnmanaged(StackValue) = .{},
    pop_in_use: bool = false,

    pub fn init(stack_alloc: Allocator, ast_alloc: Allocator) Stack {
        return .{
            .items = .{},
            .stack_alloc = stack_alloc,
            .ast_alloc = ast_alloc,
            .allow_underflow = false,
            .pop_scratch = .{},
            .pop_in_use = false,
        };
    }

    pub fn deinit(self: *Stack) void {
        for (self.items.items) |*item| {
            item.deinit(self.ast_alloc, self.stack_alloc);
        }
        self.items.deinit(self.stack_alloc);
        self.pop_scratch.deinit(self.stack_alloc);
    }

    pub fn deinitShallow(self: *Stack) void {
        self.items.deinit(self.stack_alloc);
        self.pop_scratch.deinit(self.stack_alloc);
    }

    pub fn reset(self: *Stack) void {
        for (self.items.items) |*item| {
            item.deinit(self.ast_alloc, self.stack_alloc);
        }
        self.items.clearRetainingCapacity();
        self.pop_in_use = false;
        self.pop_scratch.items.len = 0;
    }

    pub fn push(self: *Stack, value: StackValue) !void {
        try self.items.append(self.stack_alloc, value);
    }

    pub fn pop(self: *Stack) ?StackValue {
        if (self.items.items.len == 0) {
            if (self.allow_underflow) return .unknown;
            return null;
        }
        return self.items.pop();
    }

    pub fn popExpr(self: *Stack) !*Expr {
        const val = self.pop() orelse return error.StackUnderflow;
        return switch (val) {
            .expr => |e| e,
            .unknown => {
                return ast.makeName(self.ast_alloc, "__unknown__", .load);
            },
            .exc_marker => {
                return ast.makeName(self.ast_alloc, "__exception__", .load);
            },
            else => {
                if (self.allow_underflow) {
                    var tmp = val;
                    tmp.deinit(self.ast_alloc, self.stack_alloc);
                    return ast.makeName(self.ast_alloc, "__unknown__", .load);
                }
                var tmp = val;
                tmp.deinit(self.ast_alloc, self.stack_alloc);
                return error.NotAnExpression;
            },
        };
    }

    pub fn peek(self: *const Stack) ?StackValue {
        if (self.items.items.len == 0) return null;
        return self.items.items[self.items.items.len - 1];
    }

    pub fn peekExpr(self: *const Stack) ?*Expr {
        const val = self.peek() orelse return null;
        return if (val == .expr) val.expr else null;
    }

    pub fn len(self: *const Stack) usize {
        return self.items.items.len;
    }

    /// Pop n items and return them in reverse order (bottom to top becomes first to last).
    pub fn popN(self: *Stack, n: usize) ![]StackValue {
        if (!self.allow_underflow and n > self.items.items.len) return error.StackUnderflow;
        if (n == 0) return &.{};
        var result: []StackValue = undefined;
        if (!self.pop_in_use) {
            try self.pop_scratch.ensureTotalCapacity(self.stack_alloc, n);
            self.pop_scratch.items.len = n;
            self.pop_in_use = true;
            result = self.pop_scratch.items[0..n];
        } else {
            result = try self.stack_alloc.alloc(StackValue, n);
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.items.items.len == 0) {
                result[n - 1 - i] = .unknown;
            } else {
                result[n - 1 - i] = self.items.pop().?;
            }
        }
        return result;
    }

    pub fn releasePop(self: *Stack, values: []StackValue) void {
        if (values.len == 0) return;
        if (self.pop_in_use and values.ptr == self.pop_scratch.items.ptr) {
            self.pop_in_use = false;
            self.pop_scratch.items.len = 0;
            return;
        }
        self.stack_alloc.free(values);
    }

    /// Pop n expressions in reverse order.
    pub fn popNExprs(self: *Stack, n: usize) ![]const *Expr {
        const values = try self.popN(n);
        return self.valuesToExprs(values);
    }

    pub fn valuesToExprs(self: *Stack, values: []StackValue) ![]const *Expr {
        const exprs = try self.ast_alloc.alloc(*Expr, values.len);
        var created: std.ArrayListUnmanaged(*Expr) = .{};
        errdefer {
            for (created.items) |e| {
                e.deinit(self.ast_alloc);
                self.ast_alloc.destroy(e);
            }
            created.deinit(self.stack_alloc);
            for (values) |*val| {
                val.deinit(self.ast_alloc, self.stack_alloc);
            }
            self.releasePop(values);
            self.ast_alloc.free(exprs);
        }

        for (values, 0..) |v, i| {
            exprs[i] = switch (v) {
                .expr => |e| e,
                .unknown => blk: {
                    const expr = try ast.makeName(self.ast_alloc, "__unknown__", .load);
                    try created.append(self.stack_alloc, expr);
                    break :blk expr;
                },
                else => blk: {
                    if (self.allow_underflow) {
                        var tmp = v;
                        tmp.deinit(self.ast_alloc, self.stack_alloc);
                        const expr = try ast.makeName(self.ast_alloc, "__unknown__", .load);
                        try created.append(self.stack_alloc, expr);
                        break :blk expr;
                    }
                    return error.NotAnExpression;
                },
            };
        }

        self.releasePop(values);
        created.deinit(self.stack_alloc);
        return exprs;
    }
};

/// Context for stack simulation.
pub const SimContext = struct {
    pub const IterOverride = struct {
        index: u32,
        expr: ?*Expr,
    };

    allocator: Allocator,
    stack_alloc: Allocator,
    version: Version,
    /// Code object being simulated.
    code: *const pyc.Code,
    /// Class name for name-unmangling (null outside class scope).
    class_name: ?[]const u8 = null,
    /// Current stack state.
    stack: Stack,
    /// Expressions produced by inplace ops (for aug-assign detection).
    inplace_exprs: std.AutoHashMapUnmanaged(*Expr, bool) = .{},
    /// Track empty tuples built by BUILD_TUPLE 0 (used by CALL_FUNCTION_EX).
    empty_tuple_builds: std.AutoHashMapUnmanaged(*Expr, bool) = .{},
    /// Override for iterator locals (used for genexpr/listcomp code objects).
    iter_override: ?IterOverride = null,
    /// Optional comprehension builder not stored on the stack.
    comp_builder: ?*CompBuilder = null,
    /// Pending unpack for comprehension target.
    comp_unpack: ?PendingUnpack = null,
    /// Pending keyword argument names from KW_NAMES (3.11+).
    pending_kwnames: ?[]const []const u8 = null,
    /// Pending conditional expressions (linear simulation).
    pending_ifexp: std.ArrayListUnmanaged(PendingIfExp) = .{},
    /// Enable conditional expression handling in linear simulation.
    enable_ifexp: bool = false,
    /// GET_AWAITABLE was seen, next YIELD_FROM should be await.
    pending_await: bool = false,
    /// Relaxed stack simulation (used by stack-flow analysis).
    lenient: bool = false,
    /// Avoid deep deinit in stack-flow analysis.
    flow_mode: bool = false,
    /// Previous opcode (for walrus detection).
    prev_opcode: ?Opcode = null,

    pub fn init(allocator: Allocator, stack_alloc: Allocator, code: *const pyc.Code, version: Version) SimContext {
        return .{
            .allocator = allocator,
            .stack_alloc = stack_alloc,
            .version = version,
            .code = code,
            .stack = Stack.init(stack_alloc, allocator),
            .iter_override = null,
            .comp_builder = null,
            .comp_unpack = null,
            .pending_ifexp = .{},
            .enable_ifexp = false,
            .lenient = false,
            .flow_mode = false,
            .class_name = null,
            .inplace_exprs = .{},
            .empty_tuple_builds = .{},
        };
    }

    pub fn resetForClone(self: *SimContext) void {
        self.stack.reset();
        self.iter_override = null;
        self.comp_builder = null;
        if (self.comp_unpack) |*pending| {
            pending.deinit(self.allocator, self.stack_alloc);
        }
        self.comp_unpack = null;
        self.pending_kwnames = null;
        if (self.pending_ifexp.items.len > 0) {
            for (self.pending_ifexp.items) |*item| {
                item.deinit(self.allocator);
            }
            self.pending_ifexp.items.len = 0;
        }
        self.enable_ifexp = false;
        self.pending_await = false;
        self.lenient = false;
        self.flow_mode = false;
        self.prev_opcode = null;
        self.inplace_exprs.clearRetainingCapacity();
        self.empty_tuple_builds.clearRetainingCapacity();
    }

    pub fn deinit(self: *SimContext) void {
        if (self.flow_mode) {
            self.stack.deinitShallow();
            self.pending_ifexp.deinit(self.stack_alloc);
            return;
        }
        self.stack.deinit();
        self.inplace_exprs.deinit(self.stack_alloc);
        self.empty_tuple_builds.deinit(self.stack_alloc);
        if (self.pending_ifexp.items.len > 0) {
            for (self.pending_ifexp.items) |*item| {
                item.deinit(self.allocator);
            }
        }
        self.pending_ifexp.deinit(self.stack_alloc);
        if (self.iter_override) |ov| {
            if (ov.expr) |expr| {
                expr.deinit(self.allocator);
                self.allocator.destroy(expr);
            }
        }
        if (self.comp_unpack) |*pending| {
            pending.deinit(self.allocator, self.stack_alloc);
        }
    }

    fn makeName(self: *SimContext, name: []const u8, ctx: ast.ExprContext) !*Expr {
        const unmangled = try name_mangle.unmangleClassName(self.allocator, self.class_name, name);
        return ast.makeName(self.allocator, unmangled, ctx);
    }

    fn makeAttribute(self: *SimContext, value: *Expr, attr: []const u8, ctx: ast.ExprContext) !*Expr {
        const unmangled = try name_mangle.unmangleClassName(self.allocator, self.class_name, attr);
        return ast.makeAttribute(self.allocator, value, unmangled, ctx);
    }

    fn markInplaceExpr(self: *SimContext, expr: *Expr) !void {
        try self.inplace_exprs.put(self.stack_alloc, expr, true);
    }

    pub fn isInplaceExpr(self: *const SimContext, expr: *const Expr) bool {
        return self.inplace_exprs.get(@constCast(expr)) != null;
    }

    fn clearInplaceExpr(self: *SimContext, expr: *const Expr) void {
        _ = self.inplace_exprs.remove(@constCast(expr));
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

    /// Get a deref variable name (cellvars first, then freevars).
    pub fn getDeref(self: *const SimContext, idx: u32) ?[]const u8 {
        if (idx < self.code.cellvars.len) {
            return self.code.cellvars[idx];
        }
        const free_idx: usize = @as(usize, idx) - self.code.cellvars.len;
        if (free_idx < self.code.freevars.len) {
            return self.code.freevars[free_idx];
        }
        return null;
    }

    fn cloneTupleItems(self: *SimContext, allocator: Allocator, items: []const pyc.Object) Allocator.Error![]const ast.Constant {
        const cloned = try allocator.alloc(ast.Constant, items.len);
        var count: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                cloned[i].deinit(allocator);
            }
            allocator.free(cloned);
        }
        for (items, 0..) |item, idx| {
            cloned[idx] = try self.objToConstant(item);
            count += 1;
        }
        return cloned;
    }

    /// Convert a pyc.Object constant to an AST Constant.
    pub fn objToConstant(self: *SimContext, obj: pyc.Object) Allocator.Error!ast.Constant {
        return switch (obj) {
            .none => .none,
            .true_val => .true_,
            .false_val => .false_,
            .ellipsis => .ellipsis,
            .int => |v| switch (v) {
                .small => |s| .{ .int = s },
                .big => |b| .{ .big_int = try b.clone(self.allocator) },
            },
            .float => |v| .{ .float = v },
            .complex => |v| .{ .complex = .{ .real = v.real, .imag = v.imag } },
            .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
            .bytes => |b| .{ .bytes = try self.allocator.dupe(u8, b) },
            .tuple => |items| .{ .tuple = try self.cloneTupleItems(self.allocator, items) },
            .code => |c| .{ .code = c },
            else => .none,
        };
    }

    fn isConstObj(obj: pyc.Object) bool {
        return switch (obj) {
            .none, .true_val, .false_val, .ellipsis, .int, .float, .complex, .string, .bytes => true,
            .tuple => |items| {
                for (items) |item| {
                    if (!isConstObj(item)) return false;
                }
                return true;
            },
            else => false,
        };
    }

    fn constTupleExprs(self: *SimContext, items: []const ast.Constant) Allocator.Error![]const *Expr {
        const exprs = try self.allocator.alloc(*Expr, items.len);
        var count: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                exprs[i].deinit(self.allocator);
                self.allocator.destroy(exprs[i]);
            }
            self.allocator.free(exprs);
        }

        for (items, 0..) |item, idx| {
            const cloned = try ast.cloneConstant(self.allocator, item);
            const expr = try ast.makeConstant(self.allocator, cloned);
            exprs[idx] = expr;
            count += 1;
        }

        return exprs;
    }

    const ObjToExprError = Allocator.Error || error{UnsupportedConstant};

    fn objectsToExprs(self: *SimContext, items: []const pyc.Object) ObjToExprError![]const *Expr {
        const exprs = try self.allocator.alloc(*Expr, items.len);
        var count: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                exprs[i].deinit(self.allocator);
                self.allocator.destroy(exprs[i]);
            }
            self.allocator.free(exprs);
        }

        for (items, 0..) |item, idx| {
            exprs[idx] = try self.objToExpr(item);
            count += 1;
        }

        return exprs;
    }

    /// Convert a pyc.Object to a literal expression, including composites.
    pub fn objToExpr(self: *SimContext, obj: pyc.Object) ObjToExprError!*Expr {
        return switch (obj) {
            .tuple => |items| {
                const elts = try self.objectsToExprs(items);
                return ast.makeTuple(self.allocator, elts, .load);
            },
            .list => |items| {
                const elts = try self.objectsToExprs(items);
                return ast.makeList(self.allocator, elts, .load);
            },
            .set => |items| {
                const elts = try self.objectsToExprs(items);
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .set = .{ .elts = elts, .cap = elts.len } };
                return expr;
            },
            .frozenset => |items| {
                const elts = try self.objectsToExprs(items);
                const list_expr = try ast.makeList(self.allocator, elts, .load);
                errdefer {
                    list_expr.deinit(self.allocator);
                    self.allocator.destroy(list_expr);
                }
                const func = try self.makeName("frozenset", .load);
                errdefer {
                    func.deinit(self.allocator);
                    self.allocator.destroy(func);
                }
                const args = try self.allocator.alloc(*Expr, 1);
                args[0] = list_expr;
                return ast.makeCall(self.allocator, func, args);
            },
            .dict => |entries| {
                const keys = try self.allocator.alloc(?*Expr, entries.len);
                errdefer self.allocator.free(keys);
                const values = try self.allocator.alloc(*Expr, entries.len);
                errdefer self.allocator.free(values);

                var count: usize = 0;
                errdefer {
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        if (keys[i]) |k| {
                            k.deinit(self.allocator);
                            self.allocator.destroy(k);
                        }
                        values[i].deinit(self.allocator);
                        self.allocator.destroy(values[i]);
                    }
                }

                for (entries, 0..) |entry, idx| {
                    keys[idx] = try self.objToExpr(entry.key);
                    values[idx] = try self.objToExpr(entry.value);
                    count += 1;
                }

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .dict = .{ .keys = keys, .values = values } };
                return expr;
            },
            .slice => |s| {
                const lower = if (s.start.* == .none) null else try self.objToExpr(s.start.*);
                errdefer if (lower) |l| {
                    l.deinit(self.allocator);
                    self.allocator.destroy(l);
                };
                const upper = if (s.stop.* == .none) null else try self.objToExpr(s.stop.*);
                errdefer if (upper) |u| {
                    u.deinit(self.allocator);
                    self.allocator.destroy(u);
                };
                const step = if (s.step.* == .none) null else try self.objToExpr(s.step.*);
                errdefer if (step) |st| {
                    st.deinit(self.allocator);
                    self.allocator.destroy(st);
                };

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .slice = .{ .lower = lower, .upper = upper, .step = step } };
                return expr;
            },
            .code, .code_ref => error.UnsupportedConstant,
            else => {
                const constant = try self.objToConstant(obj);
                return ast.makeConstant(self.allocator, constant);
            },
        };
    }

    fn qualnameLeaf(self: *SimContext, qualname: []const u8) []const u8 {
        _ = self;
        if (qualname.len == 0) return qualname;
        var idx = qualname.len;
        while (idx > 0) {
            idx -= 1;
            if (qualname[idx] == '.') {
                if (idx + 1 < qualname.len) return qualname[idx + 1 ..];
                break;
            }
        }
        return qualname;
    }

    fn isBuildClass(self: *SimContext, callee: *const Expr) bool {
        _ = self;
        return switch (callee.*) {
            .name => |n| std.mem.eql(u8, n.id, "__build_class__"),
            else => false,
        };
    }

    fn buildClassValue(
        self: *SimContext,
        callee_expr: *Expr,
        args_vals: []StackValue,
        keywords: []ast.Keyword,
    ) !bool {
        if (args_vals.len < 2) return false;

        const func = switch (args_vals[0]) {
            .function_obj => |f| f,
            else => return false,
        };

        const name_expr = switch (args_vals[1]) {
            .expr => |e| e,
            else => return false,
        };

        const name_value = if (name_expr.* == .constant) name_expr.constant else return false;
        const name = switch (name_value) {
            .string => |s| s,
            else => return false,
        };

        for (args_vals[2..]) |val| {
            if (val != .expr) return false;
        }

        var bases: []const *Expr = &.{};
        if (args_vals.len > 2) {
            var bases_mut = try self.allocator.alloc(*Expr, args_vals.len - 2);
            errdefer if (bases_mut.len > 0) self.allocator.free(bases_mut);
            for (args_vals[2..], 0..) |val, idx| {
                bases_mut[idx] = val.expr;
            }
            bases = bases_mut;
        }

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const cls = try self.allocator.create(ClassValue);
        cls.* = .{
            .code = func.code,
            .name = name_copy,
            .bases = bases,
            .keywords = keywords,
            .decorators = .{},
        };

        func.deinit(self.allocator);
        name_expr.deinit(self.allocator);
        self.allocator.destroy(name_expr);
        callee_expr.deinit(self.allocator);
        self.allocator.destroy(callee_expr);
        self.stack.releasePop(args_vals);

        try self.stack.push(.{ .class_obj = cls });
        return true;
    }

    fn tryBuildClassValueKw(
        self: *SimContext,
        callee_expr: *Expr,
        args_vals: []StackValue,
        kw_names: []const []const u8,
    ) !bool {
        if (kw_names.len > args_vals.len) return false;
        const pos_count = args_vals.len - kw_names.len;
        if (pos_count < 2) return false;

        if (args_vals[0] != .function_obj) return false;
        const name_expr = switch (args_vals[1]) {
            .expr => |e| e,
            else => return false,
        };
        if (name_expr.* != .constant or name_expr.constant != .string) return false;
        for (args_vals[2..pos_count]) |val| {
            if (val != .expr) return false;
        }
        for (args_vals[pos_count..]) |val| {
            if (val != .expr) return false;
        }

        var keywords: []ast.Keyword = &.{};
        if (kw_names.len > 0) {
            keywords = try self.allocator.alloc(ast.Keyword, kw_names.len);
        }
        errdefer if (kw_names.len > 0) self.allocator.free(keywords);

        for (kw_names, 0..) |name, idx| {
            const value = args_vals[pos_count + idx].expr;
            keywords[idx] = .{ .arg = name, .value = value };
        }

        const pos_vals = args_vals[0..pos_count];
        if (try self.buildClassValue(callee_expr, pos_vals, keywords)) return true;

        if (kw_names.len > 0) self.allocator.free(keywords);
        return false;
    }

    fn takeClassName(self: *SimContext, value: StackValue) SimError![]const u8 {
        var owned = value;
        errdefer owned.deinit(self.allocator, self.stack_alloc);

        const expr = switch (owned) {
            .expr => |e| e,
            else => return error.NotAnExpression,
        };

        // Python 1.x/2.x uses bytes for class names, Python 3+ uses strings
        const name_bytes = switch (expr.*) {
            .constant => |c| switch (c) {
                .string => |s| s,
                .bytes => |b| b,
                else => return error.InvalidConstant,
            },
            else => return error.InvalidConstant,
        };
        const name = try self.allocator.dupe(u8, name_bytes);
        expr.deinit(self.allocator);
        self.allocator.destroy(expr);
        return name;
    }

    fn takeClassBases(self: *SimContext, value: StackValue) SimError![]const *Expr {
        var owned = value;
        const expr = switch (owned) {
            .expr => |e| e,
            else => {
                owned.deinit(self.allocator, self.stack_alloc);
                return error.NotAnExpression;
            },
        };

        if (expr.* == .tuple) {
            const bases = expr.tuple.elts;
            expr.tuple.elts = &.{};
            expr.deinit(self.allocator);
            self.allocator.destroy(expr);
            return bases;
        }

        const bases = try self.allocator.alloc(*Expr, 1);
        bases[0] = expr;
        return bases;
    }

    fn deinitStackValues(self: *SimContext, values: []StackValue) void {
        for (values) |val| {
            val.deinit(self.allocator, self.stack_alloc);
        }
        self.stack.releasePop(values);
    }

    fn deinitExprSlice(allocator: Allocator, items: []const *Expr) void {
        for (items) |item| {
            @constCast(item).deinit(allocator);
            allocator.destroy(item);
        }
        if (items.len > 0) allocator.free(items);
    }

    fn deinitKeywordsOwned(allocator: Allocator, keywords: []const ast.Keyword) void {
        for (keywords) |kw| {
            if (kw.arg) |arg| allocator.free(arg);
            kw.value.deinit(allocator);
            allocator.destroy(kw.value);
        }
        if (keywords.len > 0) allocator.free(keywords);
    }

    fn buildPosArgsAndKeywords(
        self: *SimContext,
        args_vals: []StackValue,
        kwnames: []const []const u8,
    ) SimError!struct { posargs: []StackValue, keywords: []ast.Keyword } {
        const num_kwargs = kwnames.len;
        if (args_vals.len < num_kwargs) return error.StackUnderflow;
        const num_posargs = args_vals.len - num_kwargs;

        var posargs: []StackValue = &.{};
        if (num_posargs > 0) {
            posargs = try self.stack_alloc.alloc(StackValue, num_posargs);
        }
        var pos_filled: usize = 0;

        var keywords: []ast.Keyword = &.{};
        if (num_kwargs > 0) {
            keywords = try self.allocator.alloc(ast.Keyword, num_kwargs);
        }
        var kw_filled: usize = 0;

        errdefer {
            // Deinit values not moved to keywords.
            var idx = num_posargs + kw_filled;
            while (idx < args_vals.len) : (idx += 1) {
                args_vals[idx].deinit(self.allocator, self.stack_alloc);
            }

            for (posargs[0..pos_filled]) |val| {
                val.deinit(self.allocator, self.stack_alloc);
            }
            if (posargs.len > 0) self.stack_alloc.free(posargs);

            for (keywords[0..kw_filled]) |kw| {
                if (kw.arg) |arg| self.allocator.free(arg);
                kw.value.deinit(self.allocator);
                self.allocator.destroy(kw.value);
            }
            if (keywords.len > 0) self.allocator.free(keywords);
            self.stack.releasePop(args_vals);
        }

        for (args_vals[0..num_posargs], 0..) |val, i| {
            posargs[i] = val;
            pos_filled += 1;
        }

        for (kwnames, 0..) |name, i| {
            const val = args_vals[num_posargs + i];
            const value = switch (val) {
                .expr => |e| e,
                else => return error.NotAnExpression,
            };
            const arg = try self.allocator.dupe(u8, name);
            keywords[i] = .{ .arg = arg, .value = value };
            kw_filled += 1;
        }

        self.stack.releasePop(args_vals);
        return .{ .posargs = posargs, .keywords = keywords };
    }

    fn keywordNamesFromValue(self: *SimContext, value: StackValue) SimError![]const []const u8 {
        var owned = value;
        defer owned.deinit(self.allocator, self.stack_alloc);

        const expr = switch (owned) {
            .expr => |e| e,
            else => return error.InvalidKeywordNames,
        };

        var count: usize = 0;
        switch (expr.*) {
            .tuple => |tup| {
                const elts = tup.elts;
                const names = try self.allocator.alloc([]const u8, elts.len);
                errdefer {
                    for (names[0..count]) |name| self.allocator.free(name);
                    self.allocator.free(names);
                }

                for (elts, 0..) |elt, idx| {
                    if (elt.* != .constant or elt.constant != .string) {
                        return error.InvalidKeywordNames;
                    }
                    names[idx] = try self.allocator.dupe(u8, elt.constant.string);
                    count += 1;
                }

                return names;
            },
            .constant => |c| {
                if (c != .tuple) return error.InvalidKeywordNames;
                const items = c.tuple;
                const names = try self.allocator.alloc([]const u8, items.len);
                errdefer {
                    for (names[0..count]) |name| self.allocator.free(name);
                    self.allocator.free(names);
                }

                for (items, 0..) |item, idx| {
                    if (item != .string) return error.InvalidKeywordNames;
                    names[idx] = try self.allocator.dupe(u8, item.string);
                    count += 1;
                }

                return names;
            },
            else => return error.InvalidKeywordNames,
        }
    }

    fn keywordNameFromValue(self: *SimContext, value: StackValue) SimError![]const u8 {
        var owned = value;
        errdefer owned.deinit(self.allocator, self.stack_alloc);

        const expr = switch (owned) {
            .expr => |e| e,
            else => return error.InvalidKeywordNames,
        };

        // Python 1.x/2.x uses bytes for keyword names, Python 3+ uses strings
        const name_bytes = switch (expr.*) {
            .constant => |c| switch (c) {
                .string => |s| s,
                .bytes => |b| b,
                else => return error.InvalidKeywordNames,
            },
            else => return error.InvalidKeywordNames,
        };
        const name = try self.allocator.dupe(u8, name_bytes);
        expr.deinit(self.allocator);
        self.allocator.destroy(expr);
        return name;
    }

    const UnpackedSeqKind = enum { list, tuple, set };

    fn buildStarredSequence(self: *SimContext, kind: UnpackedSeqKind, count: u32) SimError!void {
        const len: usize = @intCast(count);
        if (len == 0) {
            const expr = switch (kind) {
                .list => try ast.makeList(self.allocator, &.{}, .load),
                .tuple => try ast.makeTuple(self.allocator, &.{}, .load),
                .set => blk: {
                    const empty_set = try self.allocator.create(Expr);
                    empty_set.* = .{ .set = .{ .elts = &.{}, .cap = 0 } };
                    break :blk empty_set;
                },
            };
            try self.stack.push(.{ .expr = expr });
            return;
        }

        const items = try self.stack.popNExprs(len);
        const starred = try self.allocator.alloc(*Expr, items.len);
        var starred_count: usize = 0;
        errdefer {
            for (starred[0..starred_count]) |expr| {
                expr.deinit(self.allocator);
                self.allocator.destroy(expr);
            }
            for (items[starred_count..]) |item| {
                @constCast(item).deinit(self.allocator);
                self.allocator.destroy(item);
            }
            self.allocator.free(items);
            self.allocator.free(starred);
        }

        for (items, 0..) |item, idx| {
            starred[idx] = try ast.makeStarred(self.allocator, item, .load);
            starred_count += 1;
        }

        const expr = switch (kind) {
            .list => try ast.makeList(self.allocator, starred, .load),
            .tuple => try ast.makeTuple(self.allocator, starred, .load),
            .set => blk: {
                const set_expr = try self.allocator.create(Expr);
                set_expr.* = .{ .set = .{ .elts = starred, .cap = starred.len } };
                break :blk set_expr;
            },
        };
        try self.stack.push(.{ .expr = expr });
        self.allocator.free(items);
    }

    fn buildDictUnpack(self: *SimContext, count: u32) SimError!void {
        const len: usize = @intCast(count);
        const items = if (len == 0) &[_]*Expr{} else try self.stack.popNExprs(len);
        errdefer if (len > 0) deinitExprSlice(self.allocator, items);

        const keys = try self.allocator.alloc(?*Expr, len);
        errdefer self.allocator.free(keys);
        const values = try self.allocator.alloc(*Expr, len);
        errdefer self.allocator.free(values);

        for (items, 0..) |item, idx| {
            keys[idx] = null;
            values[idx] = item;
        }

        const expr = try self.allocator.create(Expr);
        expr.* = .{ .dict = .{ .keys = keys, .values = values } };
        try self.stack.push(.{ .expr = expr });
        if (len > 0) self.allocator.free(items);
    }

    fn appendDictMerge(self: *SimContext, dict_expr: *Expr, value_expr: *Expr) SimError!void {
        const dict = &dict_expr.dict;
        const old_len = dict.keys.len;
        const new_len = old_len + 1;

        const new_keys = try self.allocator.alloc(?*Expr, new_len);
        const new_values = try self.allocator.alloc(*Expr, new_len);
        if (old_len > 0) {
            @memcpy(new_keys[0..old_len], dict.keys);
            @memcpy(new_values[0..old_len], dict.values);
        }
        new_keys[old_len] = null;
        new_values[old_len] = value_expr;

        self.allocator.free(dict.keys);
        self.allocator.free(dict.values);
        dict.keys = new_keys;
        dict.values = new_values;
    }

    fn dictExprToKeywords(self: *SimContext, dict_expr: *Expr) SimError!?[]ast.Keyword {
        if (dict_expr.* != .dict) return null;
        const dict = &dict_expr.dict;
        if (dict.keys.len == 0) return null;

        for (dict.keys) |key_opt| {
            if (key_opt) |key| {
                if (key.* != .constant or key.constant != .string) return null;
            }
        }

        const len = dict.keys.len;
        const arg_names = try self.allocator.alloc(?[]const u8, len);
        var filled: usize = 0;
        errdefer {
            for (arg_names[0..filled]) |name_opt| {
                if (name_opt) |name| self.allocator.free(name);
            }
            self.allocator.free(arg_names);
        }

        for (dict.keys, 0..) |key_opt, idx| {
            if (key_opt) |key| {
                arg_names[idx] = try self.allocator.dupe(u8, key.constant.string);
            } else {
                arg_names[idx] = null;
            }
            filled = idx + 1;
        }

        const keywords = try self.allocator.alloc(ast.Keyword, len);
        for (dict.keys, dict.values, 0..) |key_opt, value, idx| {
            keywords[idx] = .{ .arg = arg_names[idx], .value = value };
            if (key_opt) |key| {
                key.deinit(self.allocator);
                self.allocator.destroy(key);
            }
        }

        self.allocator.free(arg_names);
        self.allocator.free(dict.keys);
        self.allocator.free(dict.values);
        self.allocator.destroy(dict_expr);
        return keywords;
    }

    fn handleCallExpr(
        self: *SimContext,
        callee_expr: *Expr,
        args_vals: []StackValue,
        keywords: []ast.Keyword,
    ) SimError!void {
        var cleanup_callee = true;
        var cleanup_args = true;
        var cleanup_keywords = keywords.len > 0;

        errdefer {
            if (cleanup_keywords) deinitKeywordsOwned(self.allocator, keywords);
            if (cleanup_callee) {
                callee_expr.deinit(self.allocator);
                self.allocator.destroy(callee_expr);
            }
            if (cleanup_args) self.deinitStackValues(args_vals);
        }

        if (keywords.len == 0 and args_vals.len == 1) {
            switch (args_vals[0]) {
                .function_obj => |func| {
                    try func.decorators.append(self.allocator, callee_expr);
                    cleanup_callee = false;
                    cleanup_args = false;
                    self.stack.releasePop(args_vals);
                    try self.stack.push(.{ .function_obj = func });
                    return;
                },
                .class_obj => |cls| {
                    try cls.decorators.append(self.allocator, callee_expr);
                    cleanup_callee = false;
                    cleanup_args = false;
                    self.stack.releasePop(args_vals);
                    try self.stack.push(.{ .class_obj = cls });
                    return;
                },
                else => {},
            }
        }

        if (self.isBuildClass(callee_expr)) {
            if (try self.buildClassValue(callee_expr, args_vals, keywords)) {
                cleanup_callee = false;
                cleanup_args = false;
                cleanup_keywords = false;
                return;
            }
        }

        const args = self.stack.valuesToExprs(args_vals) catch |err| {
            cleanup_args = false;
            return err;
        };
        cleanup_args = false;

        const expr = try ast.makeCallWithKeywords(self.allocator, callee_expr, args, keywords);
        errdefer {
            expr.deinit(self.allocator);
            self.allocator.destroy(expr);
        }
        cleanup_callee = false;
        cleanup_keywords = false;
        try self.stack.push(.{ .expr = expr });
    }

    fn ensureSetCap(self: *SimContext, set_expr: *Expr, new_len: usize) SimError!void {
        const old_len = set_expr.set.elts.len;
        if (new_len <= set_expr.set.cap) {
            if (new_len != old_len) {
                set_expr.set.elts = set_expr.set.elts.ptr[0..new_len];
            }
            return;
        }

        var new_cap: usize = if (set_expr.set.cap > 0) set_expr.set.cap else if (old_len > 0) old_len else 1;
        while (new_cap < new_len) {
            const doubled = new_cap * 2;
            if (doubled <= new_cap) return error.OutOfMemory;
            new_cap = doubled;
        }

        if (set_expr.set.cap > 0) {
            const buf = try self.allocator.realloc(@constCast(set_expr.set.elts.ptr[0..set_expr.set.cap]), new_cap);
            set_expr.set.elts = buf[0..new_len];
            set_expr.set.cap = new_cap;
            return;
        }

        const buf = try self.allocator.alloc(*Expr, new_cap);
        if (old_len > 0) {
            @memcpy(buf[0..old_len], set_expr.set.elts);
            self.allocator.free(set_expr.set.elts);
        }
        set_expr.set.elts = buf[0..new_len];
        set_expr.set.cap = new_cap;
    }

    fn appendSetElts(self: *SimContext, set_expr: *Expr, new_elts: []const *Expr) SimError!void {
        if (new_elts.len == 0) return;
        const old_len = set_expr.set.elts.len;
        if (old_len == 0 and set_expr.set.cap == 0) {
            set_expr.set.elts = new_elts;
            set_expr.set.cap = new_elts.len;
            return;
        }
        const new_len = old_len + new_elts.len;
        try self.ensureSetCap(set_expr, new_len);
        @memcpy(@constCast(set_expr.set.elts)[old_len..new_len], new_elts);
        self.allocator.free(new_elts);
    }

    fn appendSetElt(self: *SimContext, set_expr: *Expr, elt: *Expr) SimError!void {
        const old_len = set_expr.set.elts.len;
        try self.ensureSetCap(set_expr, old_len + 1);
        @constCast(set_expr.set.elts)[old_len] = elt;
    }

    fn handleCall(
        self: *SimContext,
        callable: StackValue,
        args_vals: []StackValue,
        keywords: []ast.Keyword,
        iter_expr_override: ?*Expr,
    ) SimError!void {
        if (callable == .function_obj and args_vals.len == 0 and keywords.len == 0 and self.version.lt(3, 0)) {
            const func = callable.function_obj;
            const cls = try self.allocator.create(ClassValue);
            cls.* = .{
                .code = func.code,
                .name = &.{},
                .bases = &.{},
                .keywords = &.{},
                .decorators = .{},
            };
            func.deinit(self.allocator);
            self.stack.releasePop(args_vals);
            try self.stack.push(.{ .class_obj = cls });
            return;
        }

        switch (callable) {
            .comp_obj => |comp| {
                if (keywords.len != 0) {
                    deinitKeywordsOwned(self.allocator, keywords);
                    self.deinitStackValues(args_vals);
                    return error.InvalidComprehension;
                }

                var iter_expr: ?*Expr = null;
                errdefer if (iter_expr) |expr| {
                    expr.deinit(self.allocator);
                    self.allocator.destroy(expr);
                };
                if (iter_expr_override) |override_expr| {
                    if (args_vals.len != 0) {
                        override_expr.deinit(self.allocator);
                        self.allocator.destroy(override_expr);
                        self.deinitStackValues(args_vals);
                        return error.InvalidComprehension;
                    }
                    iter_expr = override_expr;
                } else {
                    if (args_vals.len != 1) {
                        self.deinitStackValues(args_vals);
                        return error.InvalidComprehension;
                    }
                    switch (args_vals[0]) {
                        .expr => |expr| iter_expr = expr,
                        else => {
                            self.deinitStackValues(args_vals);
                            return error.NotAnExpression;
                        },
                    }
                }

                const comp_expr = try self.buildComprehensionFromCode(comp, iter_expr.?);
                iter_expr = null;
                self.stack.releasePop(args_vals);
                try self.stack.push(.{ .expr = comp_expr });
            },
            .unknown => {
                deinitKeywordsOwned(self.allocator, keywords);
                self.deinitStackValues(args_vals);
                try self.stack.push(.unknown);
                return;
            },
            .expr => |callee_expr| {
                try self.handleCallExpr(callee_expr, args_vals, keywords);
            },
            .function_obj => |func| {
                // Calling a function object directly (e.g., generic class pattern)
                const name = if (func.code.name.len > 0) func.code.name else "__anon__";
                const callee = try self.makeName(name, .load);
                try self.handleCallExpr(callee, args_vals, keywords);
            },
            else => {
                deinitKeywordsOwned(self.allocator, keywords);
                self.deinitStackValues(args_vals);
                var val = callable;
                val.deinit(self.allocator, self.stack_alloc);
                if (self.flow_mode or self.lenient) {
                    try self.stack.push(.unknown);
                    return;
                }
                return error.NotAnExpression;
            },
        }
    }

    fn resolveCallTarget(self: *SimContext, tos: StackValue, tos1: StackValue) SimError!StackValue {
        if (tos == .null_marker) {
            if (tos1 == .null_marker) return error.StackUnderflow;
            return tos1;
        }
        if (tos1 == .null_marker) {
            return tos;
        }
        if (tos == .expr) {
            tos1.deinit(self.allocator, self.stack_alloc);
            return tos;
        }
        tos1.deinit(self.allocator, self.stack_alloc);
        return tos;
    }

    pub fn cloneStackValue(self: *SimContext, value: StackValue) !StackValue {
        return switch (value) {
            .expr => |e| blk: {
                const cloned = try ast.cloneExpr(self.allocator, e);
                if (self.isInplaceExpr(e)) {
                    try self.markInplaceExpr(cloned);
                }
                break :blk .{ .expr = cloned };
            },
            .function_obj => |func| .{ .function_obj = try self.cloneFunctionValue(func) },
            .class_obj => |cls| .{ .class_obj = try self.cloneClassValue(cls) },
            .comp_builder => |builder| .{ .comp_builder = try self.cloneCompBuilder(builder) },
            .comp_obj => |comp| .{ .comp_obj = comp },
            .code_obj => |code| .{ .code_obj = code },
            .import_module => |imp| .{ .import_module = imp },
            .null_marker => .null_marker,
            .saved_local => |name| .{ .saved_local = name },
            .type_alias => |e| .{ .type_alias = try ast.cloneExpr(self.allocator, e) },
            .exc_marker => .exc_marker,
            .unknown => .unknown,
        };
    }

    pub fn cloneStackValueFlow(self: *SimContext, value: StackValue) !StackValue {
        _ = self;
        return switch (value) {
            .expr => .unknown,
            .function_obj => .unknown,
            .class_obj => .unknown,
            .comp_builder => .unknown,
            .comp_obj => |comp| .{ .comp_obj = comp },
            .code_obj => |code| .{ .code_obj = code },
            .import_module => .unknown,
            .null_marker => .null_marker,
            .type_alias => .unknown,
            .saved_local => |name| .{ .saved_local = name },
            .exc_marker => .exc_marker,
            .unknown => .unknown,
        };
    }

    fn cloneFunctionValue(self: *SimContext, func: *const FunctionValue) !*FunctionValue {
        const copy = try self.allocator.create(FunctionValue);
        errdefer self.allocator.destroy(copy);

        copy.* = .{
            .code = func.code,
            .decorators = .{},
        };

        if (func.decorators.items.len > 0) {
            try copy.decorators.ensureTotalCapacity(self.allocator, func.decorators.items.len);
            for (func.decorators.items) |decorator| {
                try copy.decorators.append(self.allocator, try ast.cloneExpr(self.allocator, decorator));
            }
        }

        return copy;
    }

    fn cloneKeywords(self: *SimContext, keywords: []const ast.Keyword) ![]const ast.Keyword {
        if (keywords.len == 0) return &.{};
        const out = try self.allocator.alloc(ast.Keyword, keywords.len);
        var count: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (out[i].arg) |arg| self.allocator.free(arg);
                out[i].value.deinit(self.allocator);
                self.allocator.destroy(out[i].value);
            }
            self.allocator.free(out);
        }
        for (keywords, 0..) |kw, idx| {
            out[idx] = .{
                .arg = if (kw.arg) |arg| try self.allocator.dupe(u8, arg) else null,
                .value = try ast.cloneExpr(self.allocator, kw.value),
            };
            count += 1;
        }
        return out;
    }

    fn cloneClassValue(self: *SimContext, cls: *const ClassValue) !*ClassValue {
        const copy = try self.allocator.create(ClassValue);
        errdefer self.allocator.destroy(copy);

        var bases: []const *Expr = &.{};
        if (cls.bases.len > 0) {
            var bases_mut = try self.allocator.alloc(*Expr, cls.bases.len);
            var count: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    bases_mut[i].deinit(self.allocator);
                    self.allocator.destroy(bases_mut[i]);
                }
                self.allocator.free(bases_mut);
            }

            for (cls.bases, 0..) |base, idx| {
                bases_mut[idx] = try ast.cloneExpr(self.allocator, base);
                count += 1;
            }
            bases = bases_mut;
        }

        const kw = try self.cloneKeywords(cls.keywords);

        copy.* = .{
            .code = cls.code,
            .name = if (cls.name.len > 0) try self.allocator.dupe(u8, cls.name) else &.{},
            .bases = bases,
            .keywords = kw,
            .decorators = .{},
        };

        if (cls.decorators.items.len > 0) {
            try copy.decorators.ensureTotalCapacity(self.allocator, cls.decorators.items.len);
            for (cls.decorators.items) |decorator| {
                try copy.decorators.append(self.allocator, try ast.cloneExpr(self.allocator, decorator));
            }
        }

        return copy;
    }

    /// Parse annotations from MAKE_FUNCTION.
    /// Annotations are a tuple of (name, annotation, ...) pairs or a dict.
    fn parseAnnotations(self: *SimContext, val: StackValue) SimError![]const signature.Annotation {
        switch (val) {
            .expr => |expr| {
                if (expr.* == .tuple) {
                    const elts = expr.tuple.elts;
                    // Pairs: name, annotation, name, annotation...
                    const count = elts.len / 2;
                    if (count == 0) return &.{};

                    const result = try self.allocator.alloc(signature.Annotation, count);
                    errdefer self.allocator.free(result);

                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const name_expr = elts[i * 2];
                        const ann_expr = elts[i * 2 + 1];
                        const name = if (name_expr.* == .constant and name_expr.constant == .string)
                            name_expr.constant.string
                        else
                            "__unknown__";
                        result[i] = .{ .name = name, .value = ann_expr };
                    }
                    return result;
                }
                if (expr.* == .dict) {
                    const keys = expr.dict.keys;
                    const values = expr.dict.values;
                    var count: usize = 0;
                    for (keys) |maybe_key| {
                        const key = maybe_key orelse continue;
                        if (key.* != .constant) continue;
                        if (key.constant != .string) continue;
                        count += 1;
                    }
                    if (count == 0) return &.{};

                    const result = try self.allocator.alloc(signature.Annotation, count);
                    errdefer self.allocator.free(result);

                    var i: usize = 0;
                    for (keys, values) |maybe_key, value| {
                        const key = maybe_key orelse continue;
                        if (key.* != .constant) continue;
                        if (key.constant != .string) continue;
                        result[i] = .{ .name = key.constant.string, .value = value };
                        i += 1;
                    }
                    return result;
                }
                // Not a tuple - discard
                expr.deinit(self.allocator);
                self.allocator.destroy(expr);
                return &.{};
            },
            else => {
                var v = val;
                v.deinit(self.allocator, self.stack_alloc);
                return &.{};
            },
        }
    }

    /// Parse annotations from PEP 649 __annotate__ code object (Python 3.14+).
    /// Two patterns exist:
    /// 1. Function annotations: LOAD_CONST name, LOAD_GLOBAL type, ..., BUILD_MAP n
    /// 2. Class annotations: BUILD_MAP 0, then (LOAD_FROM_DICT_OR_GLOBALS type, COPY, LOAD_CONST name, STORE_SUBSCR)...
    pub fn parseAnnotateCode(self: *SimContext, code: *const pyc.Code) SimError![]const signature.Annotation {
        const MiniVal = union(enum) {
            str: []const u8,
            expr: *Expr,
            dict, // marker for the dict being built
        };

        var stack: std.ArrayListUnmanaged(MiniVal) = .empty;
        defer stack.deinit(self.stack_alloc);

        // For class annotations with STORE_SUBSCR pattern
        var class_annotations: std.ArrayListUnmanaged(signature.Annotation) = .empty;
        defer class_annotations.deinit(self.stack_alloc);

        var iter = decoder.InstructionIterator.init(code.code, self.version);
        while (iter.next()) |inst| {
            switch (inst.opcode) {
                .LOAD_CONST, .LOAD_SMALL_INT => {
                    if (inst.arg < code.consts.len) {
                        const c = code.consts[inst.arg];
                        if (c == .string) {
                            try stack.append(self.stack_alloc, .{ .str = c.string });
                        } else {
                            // Type could be a constant (e.g., None)
                            const expr = try self.allocator.create(Expr);
                            expr.* = .{ .constant = try self.objToConstant(c) };
                            try stack.append(self.stack_alloc, .{ .expr = expr });
                        }
                    }
                },
                .LOAD_GLOBAL, .LOAD_NAME => {
                    const name_idx: usize = if (inst.opcode == .LOAD_GLOBAL and self.version.gte(3, 11))
                        inst.arg >> 1
                    else
                        inst.arg;
                    if (name_idx < code.names.len) {
                        const name = code.names[name_idx];
                        const expr = try self.allocator.create(Expr);
                        expr.* = .{ .name = .{ .id = name, .ctx = .load } };
                        try stack.append(self.stack_alloc, .{ .expr = expr });
                    }
                },
                .LOAD_FROM_DICT_OR_GLOBALS => {
                    // Used in class annotations - pops dict, pushes looked-up value
                    // Stack: [dict, classdict] -> [dict, type]
                    if (stack.items.len > 0) {
                        _ = stack.pop(); // pop classdict
                    }
                    // Push the type from names
                    const name_idx: usize = inst.arg;
                    if (name_idx < code.names.len) {
                        const name = code.names[name_idx];
                        const expr = try self.allocator.create(Expr);
                        expr.* = .{ .name = .{ .id = name, .ctx = .load } };
                        try stack.append(self.stack_alloc, .{ .expr = expr });
                    }
                },
                .LOAD_FROM_DICT_OR_DEREF => {
                    // Used in generic class annotations - pops dict, looks up deref
                    // Stack: [dict, classdict] -> [dict, type]
                    if (stack.items.len > 0) {
                        _ = stack.pop(); // pop classdict
                    }
                    // Push the type from varnames (localsplusnames in Python 3.11+)
                    if (inst.arg < code.varnames.len) {
                        const name = code.varnames[inst.arg];
                        if (name.len > 0 and name[0] != '.') {
                            const expr = try self.allocator.create(Expr);
                            expr.* = .{ .name = .{ .id = name, .ctx = .load } };
                            try stack.append(self.stack_alloc, .{ .expr = expr });
                        }
                    }
                },
                .LOAD_DEREF, .LOAD_FAST, .LOAD_FAST_BORROW => {
                    // For generic function annotations, LOAD_DEREF loads type params
                    // In Python 3.11+, index is into localsplusnames (stored in varnames)
                    if (inst.arg < code.varnames.len) {
                        const name = code.varnames[inst.arg];
                        // For class annotations with __classdict__, just push placeholder
                        if (std.mem.eql(u8, name, "__classdict__")) {
                            try stack.append(self.stack_alloc, .dict);
                        } else if (name.len > 0 and name[0] != '.') {
                            // Type parameter or other variable - create name expression
                            const expr = try self.allocator.create(Expr);
                            expr.* = .{ .name = .{ .id = name, .ctx = .load } };
                            try stack.append(self.stack_alloc, .{ .expr = expr });
                        } else {
                            // Internal variable like .format - push placeholder
                            try stack.append(self.stack_alloc, .dict);
                        }
                    } else {
                        try stack.append(self.stack_alloc, .dict);
                    }
                },
                .COPY => {
                    // COPY n - duplicates TOS to position n
                    // For class annotations: [dict, type] -> [dict, type, dict]
                    if (stack.items.len > 0) {
                        const n = inst.arg;
                        if (n > 0 and n <= stack.items.len) {
                            const idx = stack.items.len - n;
                            const val = stack.items[idx];
                            try stack.append(self.stack_alloc, val);
                        }
                    }
                },
                .LOAD_ATTR => {
                    // For attribute access like typing.Optional
                    const name_idx: usize = if (self.version.gte(3, 12))
                        inst.arg >> 1
                    else
                        inst.arg;
                    if (name_idx < code.names.len and stack.items.len > 0) {
                        const attr_name = code.names[name_idx];
                        const val = stack.pop() orelse continue;
                        if (val == .expr) {
                            const attr = try self.allocator.create(Expr);
                            attr.* = .{ .attribute = .{
                                .value = val.expr,
                                .attr = attr_name,
                                .ctx = .load,
                            } };
                            try stack.append(self.stack_alloc, .{ .expr = attr });
                        }
                    }
                },
                .BINARY_SUBSCR => {
                    // For subscript like list[int]
                    if (stack.items.len >= 2) {
                        const slice = stack.pop() orelse continue;
                        const value = stack.pop() orelse continue;
                        if (value == .expr and slice == .expr) {
                            const subscr = try self.allocator.create(Expr);
                            subscr.* = .{ .subscript = .{
                                .value = value.expr,
                                .slice = slice.expr,
                                .ctx = .load,
                            } };
                            try stack.append(self.stack_alloc, .{ .expr = subscr });
                        }
                    }
                },
                .BINARY_OP => {
                    // BINARY_OP arg 26 is NB_SUBSCR (subscript operation) in Python 3.14+
                    if (inst.arg == 26 and stack.items.len >= 2) {
                        const slice = stack.pop() orelse continue;
                        const value = stack.pop() orelse continue;
                        if (value == .expr and slice == .expr) {
                            const subscr = try self.allocator.create(Expr);
                            subscr.* = .{ .subscript = .{
                                .value = value.expr,
                                .slice = slice.expr,
                                .ctx = .load,
                            } };
                            try stack.append(self.stack_alloc, .{ .expr = subscr });
                        }
                    }
                },
                .STORE_SUBSCR => {
                    // For class annotations: dict[key] = value
                    // Stack before: [dict, type, dict_copy, key]
                    // Pops: key, dict_copy, type; stores dict_copy[key] = type
                    // Stack after: [dict]
                    if (stack.items.len >= 4) {
                        const key = stack.pop() orelse continue;
                        _ = stack.pop(); // dict_copy
                        const type_val = stack.pop() orelse continue;

                        const name = if (key == .str) key.str else "__unknown__";
                        const type_expr: *Expr = if (type_val == .expr) type_val.expr else blk: {
                            const expr = try self.allocator.create(Expr);
                            expr.* = .{ .constant = .none };
                            break :blk expr;
                        };
                        try class_annotations.append(self.stack_alloc, .{
                            .name = name,
                            .value = type_expr,
                        });
                    }
                },
                .BUILD_TUPLE => {
                    // For tuple[int, str] slices
                    const n = inst.arg;
                    if (n <= stack.items.len) {
                        const elts = try self.allocator.alloc(*Expr, n);
                        var i: usize = 0;
                        while (i < n) : (i += 1) {
                            const idx = stack.items.len - n + i;
                            if (stack.items[idx] == .expr) {
                                elts[i] = stack.items[idx].expr;
                            } else {
                                // String not expected here, create name
                                const expr = try self.allocator.create(Expr);
                                expr.* = .{ .constant = .{ .string = if (stack.items[idx] == .str) stack.items[idx].str else "" } };
                                elts[i] = expr;
                            }
                        }
                        stack.items.len -= n;
                        const tuple = try self.allocator.create(Expr);
                        tuple.* = .{ .tuple = .{ .elts = elts, .ctx = .load } };
                        try stack.append(self.stack_alloc, .{ .expr = tuple });
                    }
                },
                .BUILD_MAP => {
                    const n = inst.arg;
                    if (n == 0) {
                        // Class annotation pattern: BUILD_MAP 0, then STORE_SUBSCR
                        try stack.append(self.stack_alloc, .dict);
                        continue;
                    }
                    // Function annotation pattern: items already on stack
                    if (n * 2 > stack.items.len) return &.{};

                    const result = try self.allocator.alloc(signature.Annotation, n);
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        const base_idx = stack.items.len - n * 2 + i * 2;
                        const name_val = stack.items[base_idx];
                        const type_val = stack.items[base_idx + 1];

                        const name = if (name_val == .str) name_val.str else "__unknown__";
                        const type_expr = if (type_val == .expr) type_val.expr else blk: {
                            const expr = try self.allocator.create(Expr);
                            expr.* = .{ .constant = .{ .string = if (type_val == .str) type_val.str else "" } };
                            break :blk expr;
                        };
                        result[i] = .{ .name = name, .value = type_expr };
                    }
                    return result;
                },
                .RETURN_VALUE, .RETURN_CONST => {
                    // If we collected class annotations via STORE_SUBSCR, return those
                    if (class_annotations.items.len > 0) {
                        const result = try self.allocator.alloc(signature.Annotation, class_annotations.items.len);
                        @memcpy(result, class_annotations.items);
                        return result;
                    }
                    break;
                },
                else => {},
            }
        }
        return &.{};
    }

    /// Parse type alias code object (PEP 695) to extract the type expression.
    /// Pattern: LOAD_GLOBAL type, BUILD_TUPLE n, BINARY_OP 26 (subscript), RETURN_VALUE
    pub fn parseTypeAliasCode(self: *SimContext, code: *const pyc.Code) SimError!*Expr {
        const MiniVal = union(enum) {
            expr: *Expr,
        };

        var stack: std.ArrayListUnmanaged(MiniVal) = .empty;
        defer stack.deinit(self.stack_alloc);

        var iter = decoder.InstructionIterator.init(code.code, self.version);
        while (iter.next()) |inst| {
            switch (inst.opcode) {
                .LOAD_CONST, .LOAD_SMALL_INT => {
                    if (inst.arg < code.consts.len) {
                        const c = code.consts[inst.arg];
                        const expr = try self.allocator.create(Expr);
                        expr.* = .{ .constant = try self.objToConstant(c) };
                        try stack.append(self.stack_alloc, .{ .expr = expr });
                    }
                },
                .LOAD_GLOBAL, .LOAD_NAME => {
                    const name_idx: usize = if (inst.opcode == .LOAD_GLOBAL and self.version.gte(3, 11))
                        inst.arg >> 1
                    else
                        inst.arg;
                    if (name_idx < code.names.len) {
                        const name = code.names[name_idx];
                        const expr = try self.allocator.create(Expr);
                        expr.* = .{ .name = .{ .id = name, .ctx = .load } };
                        try stack.append(self.stack_alloc, .{ .expr = expr });
                    }
                },
                .LOAD_DEREF, .LOAD_FAST, .LOAD_FAST_BORROW => {
                    // For generic type parameters (freevars)
                    // In Python 3.11+, LOAD_DEREF uses localsplusnames index
                    // which is stored in code.varnames
                    const name: ?[]const u8 = if (inst.arg < code.varnames.len)
                        code.varnames[inst.arg]
                    else
                        null;
                    if (name) |n| {
                        // Skip internal names like .format
                        if (n.len > 0 and n[0] != '.') {
                            const expr = try self.allocator.create(Expr);
                            expr.* = .{ .name = .{ .id = n, .ctx = .load } };
                            try stack.append(self.stack_alloc, .{ .expr = expr });
                        }
                    }
                },
                .LOAD_ATTR => {
                    const name_idx: usize = if (self.version.gte(3, 12))
                        inst.arg >> 1
                    else
                        inst.arg;
                    if (name_idx < code.names.len and stack.items.len > 0) {
                        const attr_name = code.names[name_idx];
                        const val = stack.pop().?;
                        const attr = try self.allocator.create(Expr);
                        attr.* = .{ .attribute = .{
                            .value = val.expr,
                            .attr = attr_name,
                            .ctx = .load,
                        } };
                        try stack.append(self.stack_alloc, .{ .expr = attr });
                    }
                },
                .BINARY_SUBSCR => {
                    if (stack.items.len >= 2) {
                        const slice = stack.pop().?;
                        const value = stack.pop().?;
                        const subscr = try self.allocator.create(Expr);
                        subscr.* = .{ .subscript = .{
                            .value = value.expr,
                            .slice = slice.expr,
                            .ctx = .load,
                        } };
                        try stack.append(self.stack_alloc, .{ .expr = subscr });
                    }
                },
                .BINARY_OP => {
                    if (stack.items.len >= 2) {
                        if (inst.arg == 26) {
                            // BINARY_OP 26 is subscript in Python 3.14+
                            const slice = stack.pop().?;
                            const value = stack.pop().?;
                            const subscr = try self.allocator.create(Expr);
                            subscr.* = .{ .subscript = .{
                                .value = value.expr,
                                .slice = slice.expr,
                                .ctx = .load,
                            } };
                            try stack.append(self.stack_alloc, .{ .expr = subscr });
                        } else if (inst.arg == 7) {
                            // BINARY_OP 7 is bitor (|) for union types
                            const right = stack.pop().?;
                            const left = stack.pop().?;
                            const binop = try self.allocator.create(Expr);
                            binop.* = .{ .bin_op = .{
                                .left = left.expr,
                                .op = .bitor,
                                .right = right.expr,
                            } };
                            try stack.append(self.stack_alloc, .{ .expr = binop });
                        }
                    }
                },
                .BUILD_TUPLE => {
                    const n = inst.arg;
                    if (n <= stack.items.len) {
                        const elts = try self.allocator.alloc(*Expr, n);
                        var i: usize = 0;
                        while (i < n) : (i += 1) {
                            const idx = stack.items.len - n + i;
                            elts[i] = stack.items[idx].expr;
                        }
                        stack.items.len -= n;
                        const tuple = try self.allocator.create(Expr);
                        tuple.* = .{ .tuple = .{ .elts = elts, .ctx = .load } };
                        try stack.append(self.stack_alloc, .{ .expr = tuple });
                    }
                },
                .BUILD_LIST => {
                    const n = inst.arg;
                    if (n <= stack.items.len) {
                        const elts = try self.allocator.alloc(*Expr, n);
                        var i: usize = 0;
                        while (i < n) : (i += 1) {
                            const idx = stack.items.len - n + i;
                            elts[i] = stack.items[idx].expr;
                        }
                        stack.items.len -= n;
                        const list_expr = try self.allocator.create(Expr);
                        list_expr.* = .{ .list = .{ .elts = elts, .ctx = .load } };
                        try stack.append(self.stack_alloc, .{ .expr = list_expr });
                    }
                },
                .RETURN_VALUE, .RETURN_CONST => {
                    // Return TOS as the type expression
                    if (stack.items.len > 0) {
                        return stack.items[stack.items.len - 1].expr;
                    }
                    break;
                },
                else => {},
            }
        }
        // Return unknown if we couldn't parse
        const expr = try self.allocator.create(Expr);
        expr.* = .{ .name = .{ .id = "__unknown__", .ctx = .load } };
        return expr;
    }

    pub const GenericTypeAliasResult = struct {
        type_params: []const []const u8,
        value: ?*Expr,
    };

    /// Parse a generic type alias code object (the <generic parameters of X> code).
    /// Extracts type parameters and the type value expression.
    /// Returns null value if this is not a type alias (e.g., it's a generic function).
    pub fn parseGenericTypeAliasCode(self: *SimContext, code: *const pyc.Code) SimError!GenericTypeAliasResult {
        var type_params: std.ArrayListUnmanaged([]const u8) = .empty;
        defer type_params.deinit(self.stack_alloc);

        var inner_code: ?*const pyc.Code = null;
        var found_typealias_intrinsic = false;

        // Scan for CALL_INTRINSIC_1 11 (TYPEALIAS) to verify this is a type alias
        // Generic functions use CALL_INTRINSIC_2 4 (SET_FUNCTION_TYPE_PARAMS) instead
        var iter = decoder.InstructionIterator.init(code.code, self.version);
        while (iter.next()) |inst| {
            switch (inst.opcode) {
                .CALL_INTRINSIC_1 => {
                    if (inst.arg == 11) {
                        // INTRINSIC_TYPEALIAS - this is indeed a type alias
                        found_typealias_intrinsic = true;
                    }
                },
                .CALL_INTRINSIC_2 => {
                    if (inst.arg == 4) {
                        // INTRINSIC_SET_FUNCTION_TYPE_PARAMS - this is a generic function, not a type alias
                        return .{ .type_params = &.{}, .value = null };
                    }
                },
                .LOAD_CONST => {
                    // Check if this loads a code object that could be the inner type alias
                    if (inst.arg < code.consts.len) {
                        const c = code.consts[inst.arg];
                        if (c == .code or c == .code_ref) {
                            const inner = if (c == .code) c.code else c.code_ref;
                            // Check if this is NOT the generic parameters code or __annotate__
                            if (!std.mem.startsWith(u8, inner.name, "<generic parameters") and
                                !std.mem.eql(u8, inner.name, "__annotate__"))
                            {
                                inner_code = inner;
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // If we didn't find CALL_INTRINSIC_1 11, this is not a type alias
        if (!found_typealias_intrinsic) {
            return .{ .type_params = &.{}, .value = null };
        }

        // Extract type parameters from cellvars (they're stored with STORE_DEREF)
        for (code.cellvars) |cv| {
            // Filter out internal names
            if (cv.len > 0 and cv[0] != '.' and !std.mem.eql(u8, cv, "__classcell__")) {
                try type_params.append(self.stack_alloc, cv);
            }
        }

        // Parse the inner code to get the actual type expression
        const value = if (inner_code) |ic|
            try self.parseTypeAliasCode(ic)
        else
            null;

        const params_slice = try self.allocator.alloc([]const u8, type_params.items.len);
        @memcpy(params_slice, type_params.items);

        return .{
            .type_params = params_slice,
            .value = value,
        };
    }

    pub const GenericFunctionResult = struct {
        type_params: []const []const u8,
        func_code: ?*const pyc.Code,
        annotate_code: ?*const pyc.Code,
        return_annotation: ?*Expr,
    };

    /// Parse a generic function/class code object (the <generic parameters of X> code).
    /// Extracts type parameters and the function/class code object.
    pub fn parseGenericFunctionCode(self: *SimContext, code: *const pyc.Code) SimError!GenericFunctionResult {
        var type_params: std.ArrayListUnmanaged([]const u8) = .empty;
        defer type_params.deinit(self.stack_alloc);

        var func_code: ?*const pyc.Code = null;
        var annotate_code: ?*const pyc.Code = null;
        var found_set_type_params = false;

        // Scan for CALL_INTRINSIC_2 4 (SET_FUNCTION_TYPE_PARAMS)
        var iter = decoder.InstructionIterator.init(code.code, self.version);
        while (iter.next()) |inst| {
            switch (inst.opcode) {
                .CALL_INTRINSIC_2 => {
                    if (inst.arg == 4) {
                        // INTRINSIC_SET_FUNCTION_TYPE_PARAMS - this is a generic function
                        found_set_type_params = true;
                    }
                },
                .CALL_INTRINSIC_1 => {
                    if (inst.arg == 11) {
                        // INTRINSIC_TYPEALIAS - this is a type alias, not a function
                        return .{ .type_params = &.{}, .func_code = null, .annotate_code = null, .return_annotation = null };
                    }
                },
                .LOAD_CONST => {
                    // Check if this loads a code object
                    if (inst.arg < code.consts.len) {
                        const c = code.consts[inst.arg];
                        if (c == .code or c == .code_ref) {
                            const inner = if (c == .code) c.code else c.code_ref;
                            if (std.mem.eql(u8, inner.name, "__annotate__")) {
                                annotate_code = inner;
                            } else if (!std.mem.startsWith(u8, inner.name, "<generic parameters")) {
                                func_code = inner;
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // If we didn't find CALL_INTRINSIC_2 4, this is not a generic function
        if (!found_set_type_params) {
            return .{ .type_params = &.{}, .func_code = null, .annotate_code = null, .return_annotation = null };
        }

        // Extract type parameters from cellvars
        for (code.cellvars) |cv| {
            if (cv.len > 0 and cv[0] != '.' and !std.mem.eql(u8, cv, "__classcell__")) {
                try type_params.append(self.stack_alloc, cv);
            }
        }

        // Try to get return annotation from __annotate__ code
        var return_annotation: ?*Expr = null;
        if (annotate_code) |ann_code| {
            const annotations = try self.parseAnnotateCode(ann_code);
            for (annotations) |ann| {
                if (std.mem.eql(u8, ann.name, "return")) {
                    return_annotation = ann.value;
                    break;
                }
            }
        }

        const params_slice = try self.allocator.alloc([]const u8, type_params.items.len);
        @memcpy(params_slice, type_params.items);

        return .{
            .type_params = params_slice,
            .func_code = func_code,
            .annotate_code = annotate_code,
            .return_annotation = return_annotation,
        };
    }

    pub const GenericClassResult = struct {
        type_params: []const []const u8,
        class_code: ?*const pyc.Code,
    };

    /// Parse a generic class code object (the <generic parameters of X> code).
    /// Extracts type parameters and the class code object.
    pub fn parseGenericClassCode(self: *SimContext, code: *const pyc.Code) SimError!GenericClassResult {
        var type_params: std.ArrayListUnmanaged([]const u8) = .empty;
        defer type_params.deinit(self.stack_alloc);

        var class_code: ?*const pyc.Code = null;
        var found_build_class = false;

        // Scan for LOAD_BUILD_CLASS (indicates this is a class, not a function)
        var iter = decoder.InstructionIterator.init(code.code, self.version);
        while (iter.next()) |inst| {
            switch (inst.opcode) {
                .LOAD_BUILD_CLASS => {
                    found_build_class = true;
                },
                .CALL_INTRINSIC_1 => {
                    if (inst.arg == 11) {
                        // INTRINSIC_TYPEALIAS - this is a type alias, not a class
                        return .{ .type_params = &.{}, .class_code = null };
                    }
                },
                .CALL_INTRINSIC_2 => {
                    if (inst.arg == 4) {
                        // INTRINSIC_SET_FUNCTION_TYPE_PARAMS - this is a function, not a class
                        return .{ .type_params = &.{}, .class_code = null };
                    }
                },
                .LOAD_CONST => {
                    // Check if this loads a code object
                    if (inst.arg < code.consts.len) {
                        const c = code.consts[inst.arg];
                        if (c == .code or c == .code_ref) {
                            const inner = if (c == .code) c.code else c.code_ref;
                            // Class code objects don't start with special prefixes
                            if (!std.mem.startsWith(u8, inner.name, "<generic parameters") and
                                !std.mem.eql(u8, inner.name, "__annotate__"))
                            {
                                class_code = inner;
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // If we didn't find LOAD_BUILD_CLASS, this is not a generic class
        if (!found_build_class) {
            return .{ .type_params = &.{}, .class_code = null };
        }

        // For generic classes, type parameters are stored in varnames via STORE_FAST
        // They're the names that come from CALL_INTRINSIC_1 7 (INTRINSIC_TYPEVAR)
        // Look for pattern: LOAD_CONST 'T', CALL_INTRINSIC_1 7, COPY, STORE_FAST T
        iter = decoder.InstructionIterator.init(code.code, self.version);
        var prev_was_typevar = false;
        while (iter.next()) |inst| {
            switch (inst.opcode) {
                .CALL_INTRINSIC_1 => {
                    if (inst.arg == 7) {
                        prev_was_typevar = true;
                    }
                },
                .STORE_FAST => {
                    if (prev_was_typevar and inst.arg < code.varnames.len) {
                        const name = code.varnames[inst.arg];
                        if (name.len > 0 and name[0] != '.') {
                            try type_params.append(self.stack_alloc, name);
                        }
                    }
                    prev_was_typevar = false;
                },
                .STORE_DEREF => {
                    // For complex generic classes, type params may be stored as cells
                    // In Python 3.11+, STORE_DEREF uses localsplusnames index (stored in varnames)
                    if (prev_was_typevar and inst.arg < code.varnames.len) {
                        const name = code.varnames[inst.arg];
                        if (name.len > 0 and name[0] != '.') {
                            try type_params.append(self.stack_alloc, name);
                        }
                    }
                    prev_was_typevar = false;
                },
                .COPY => {
                    // COPY is between CALL_INTRINSIC_1 and STORE_FAST/STORE_DEREF, keep prev_was_typevar
                },
                else => {
                    prev_was_typevar = false;
                },
            }
        }

        const params_slice = try self.allocator.alloc([]const u8, type_params.items.len);
        @memcpy(params_slice, type_params.items);

        return .{
            .type_params = params_slice,
            .class_code = class_code,
        };
    }

    /// Parse keyword defaults dict from MAKE_FUNCTION.
    fn parseKwDefaults(self: *SimContext, val: StackValue, code_opt: ?*const pyc.Code) SimError![]const ?*Expr {
        const code = code_opt orelse {
            var v = val;
            v.deinit(self.allocator, self.stack_alloc);
            return &.{};
        };
        if (code.kwonlyargcount == 0) {
            var v = val;
            v.deinit(self.allocator, self.stack_alloc);
            return &.{};
        }

        const kw_count: usize = @intCast(code.kwonlyargcount);
        const out = try self.allocator.alloc(?*Expr, kw_count);
        @memset(out, null);

        var expr_opt: ?*Expr = null;
        switch (val) {
            .expr => |expr| expr_opt = expr,
            else => {
                var v = val;
                v.deinit(self.allocator, self.stack_alloc);
                return out;
            },
        }

        const dict_expr = expr_opt.?;
        defer {
            dict_expr.deinit(self.allocator);
            self.allocator.destroy(dict_expr);
        }

        if (dict_expr.* != .dict) {
            return out;
        }

        const keys = dict_expr.dict.keys;
        const values = dict_expr.dict.values;

        const kw_start: usize = @intCast(code.argcount);

        for (keys, values) |maybe_key, value| {
            const key = maybe_key orelse continue;
            if (key.* != .constant) continue;
            if (key.constant != .string) continue;
            const name = key.constant.string;
            var i: usize = 0;
            while (i < kw_count) : (i += 1) {
                const idx = kw_start + i;
                if (idx >= code.varnames.len) break;
                if (std.mem.eql(u8, code.varnames[idx], name)) {
                    out[i] = try ast.cloneExpr(self.allocator, value);
                    break;
                }
            }
        }

        return out;
    }

    /// Parse defaults tuple from MAKE_FUNCTION.
    fn parseDefaults(self: *SimContext, val: StackValue) SimError![]const *Expr {
        switch (val) {
            .expr => |expr| {
                switch (expr.*) {
                    .tuple => return expr.tuple.elts,
                    .constant => |c| switch (c) {
                        .tuple => |items| {
                            const exprs = try self.constTupleExprs(items);
                            expr.deinit(self.allocator);
                            self.allocator.destroy(expr);
                            return exprs;
                        },
                        else => {},
                    },
                    else => {},
                }
                expr.deinit(self.allocator);
                self.allocator.destroy(expr);
                return &.{};
            },
            else => {
                var v = val;
                v.deinit(self.allocator, self.stack_alloc);
                return &.{};
            },
        }
    }

    fn cloneCompBuilder(self: *SimContext, builder: *const CompBuilder) !*CompBuilder {
        const copy = try self.stack_alloc.create(CompBuilder);
        errdefer copy.deinit(self.allocator, self.stack_alloc);

        copy.* = CompBuilder.init(builder.kind);
        copy.seen_append = builder.seen_append;

        if (builder.elt) |elt| {
            copy.elt = try ast.cloneExpr(self.allocator, elt);
        }
        if (builder.key) |key| {
            copy.key = try ast.cloneExpr(self.allocator, key);
        }
        if (builder.value) |value| {
            copy.value = try ast.cloneExpr(self.allocator, value);
        }

        if (builder.generators.items.len > 0) {
            try copy.generators.ensureTotalCapacity(self.stack_alloc, builder.generators.items.len);
            for (builder.generators.items) |gen| {
                const iter_expr = gen.iter orelse return error.InvalidComprehension;
                var gen_copy = PendingComp{
                    .target = if (gen.target) |target| try ast.cloneExpr(self.allocator, target) else null,
                    .iter = try ast.cloneExpr(self.allocator, iter_expr),
                    .ifs = .{},
                    .is_async = gen.is_async,
                };
                var appended = false;
                errdefer if (!appended) gen_copy.deinit(self.allocator, self.stack_alloc);

                if (gen.ifs.items.len > 0) {
                    try gen_copy.ifs.ensureTotalCapacity(self.stack_alloc, gen.ifs.items.len);
                    for (gen.ifs.items) |cond| {
                        try gen_copy.ifs.append(self.stack_alloc, try ast.cloneExpr(self.allocator, cond));
                    }
                }

                try copy.generators.append(self.stack_alloc, gen_copy);
                appended = true;
            }
        }

        if (builder.loop_stack.items.len > 0) {
            try copy.loop_stack.ensureTotalCapacity(self.stack_alloc, builder.loop_stack.items.len);
            for (builder.loop_stack.items) |idx| {
                try copy.loop_stack.append(self.stack_alloc, idx);
            }
        }

        return copy;
    }

    fn stackIndexFromDepth(self: *const SimContext, depth: u32) !usize {
        const len = self.stack.items.items.len;
        if (depth == 0) return error.InvalidStackDepth;
        if (depth > len) return error.StackUnderflow;
        return len - @as(usize, depth);
    }

    fn findCompContainer(self: *SimContext) ?struct { idx: usize, kind: CompKind } {
        var i = self.stack.items.items.len;
        while (i > 0) : (i -= 1) {
            const idx = i - 1;
            switch (self.stack.items.items[idx]) {
                .comp_builder => |builder| return .{ .idx = idx, .kind = builder.kind },
                .expr => |expr| switch (expr.*) {
                    .list => |v| if (v.elts.len == 0) return .{ .idx = idx, .kind = .list },
                    .set => |v| if (v.elts.len == 0) return .{ .idx = idx, .kind = .set },
                    .dict => |v| if (v.keys.len == 0 and v.values.len == 0) return .{ .idx = idx, .kind = .dict },
                    else => {},
                },
                else => {},
            }
        }
        return null;
    }

    fn isBuilderOnStack(self: *SimContext, builder: *const CompBuilder) bool {
        for (self.stack.items.items) |item| {
            if (item == .comp_builder and item.comp_builder == builder) return true;
        }
        return false;
    }

    fn findActiveCompBuilder(self: *SimContext) ?*CompBuilder {
        if (self.comp_builder) |builder| return builder;
        const container = self.findCompContainer() orelse return null;
        return switch (self.stack.items.items[container.idx]) {
            .comp_builder => |builder| builder,
            else => null,
        };
    }

    fn ensureCompBuilderAt(self: *SimContext, idx: usize, kind: CompKind) !*CompBuilder {
        switch (self.stack.items.items[idx]) {
            .comp_builder => |builder| return builder,
            .expr => |expr| {
                const matches = switch (expr.*) {
                    .list => |v| kind == .list and v.elts.len == 0,
                    .set => |v| kind == .set and v.elts.len == 0,
                    .dict => |v| kind == .dict and v.keys.len == 0 and v.values.len == 0,
                    else => false,
                };
                if (!matches) return error.InvalidComprehension;

                const builder = try self.stack_alloc.create(CompBuilder);
                builder.* = CompBuilder.init(kind);
                expr.deinit(self.allocator);
                self.allocator.destroy(expr);
                self.stack.items.items[idx] = .{ .comp_builder = builder };
                return builder;
            },
            else => return error.InvalidComprehension,
        }
    }

    fn getBuilderAtDepth(self: *SimContext, depth: u32, kind: CompKind) !*CompBuilder {
        const idx = self.stackIndexFromDepth(depth) catch |err| {
            if (err != error.StackUnderflow) return err;
            const len = self.stack.items.items.len;
            const missing: usize = @intCast(depth - @as(u32, @intCast(len)));
            const builder = try self.stack_alloc.create(CompBuilder);
            builder.* = CompBuilder.init(kind);
            try self.stack.items.ensureTotalCapacity(self.stack_alloc, len + missing);
            self.stack.items.items.len = len + missing;
            if (len > 0) {
                @memmove(self.stack.items.items[missing .. missing + len], self.stack.items.items[0..len]);
            }
            self.stack.items.items[0] = .{ .comp_builder = builder };
            var i: usize = 1;
            while (i < missing) : (i += 1) {
                self.stack.items.items[i] = .unknown;
            }
            return builder;
        };
        return self.ensureCompBuilderAt(idx, kind);
    }

    fn addCompGenerator(self: *SimContext, builder: *CompBuilder, iter_expr: *Expr) !void {
        var pending = PendingComp{
            .target = null,
            .iter = iter_expr,
            .ifs = .{},
            .is_async = false,
        };
        errdefer pending.deinit(self.allocator, self.stack_alloc);

        const gen_idx = builder.generators.items.len;
        try builder.loop_stack.append(self.stack_alloc, gen_idx);
        errdefer builder.loop_stack.items.len -= 1;

        try builder.generators.append(self.stack_alloc, pending);
    }

    fn addCompTarget(self: *SimContext, builder: *CompBuilder, target: *Expr) !void {
        if (builder.loop_stack.items.len == 0) return error.InvalidComprehension;
        const idx = builder.loop_stack.items[builder.loop_stack.items.len - 1];
        var slot = &builder.generators.items[idx];
        if (slot.target) |old| {
            old.deinit(self.allocator);
            self.allocator.destroy(old);
        }
        slot.target = target;
    }

    fn addCompIf(self: *SimContext, builder: *CompBuilder, cond: *Expr) !void {
        if (builder.loop_stack.items.len == 0) return error.InvalidComprehension;
        const idx = builder.loop_stack.items[builder.loop_stack.items.len - 1];
        try builder.generators.items[idx].ifs.append(self.stack_alloc, cond);
    }

    fn addCompTargetName(self: *SimContext, name: []const u8) !void {
        const builder = self.findActiveCompBuilder() orelse return;
        if (builder.loop_stack.items.len == 0) return;
        const target = try self.makeName(name, .store);
        try self.addCompTarget(builder, target);
    }

    fn startCompUnpack(self: *SimContext, count: u32) !void {
        if (self.comp_unpack != null) return;
        const builder = self.findActiveCompBuilder() orelse return;
        if (builder.loop_stack.items.len == 0) return;
        var pending = PendingUnpack{
            .builder = builder,
            .remain = count,
            .names = .{},
        };
        try pending.names.ensureTotalCapacity(self.stack_alloc, count);
        self.comp_unpack = pending;
    }

    fn consumeCompUnpackName(self: *SimContext, name: []const u8) !bool {
        if (self.comp_unpack) |*pending| {
            const target = try self.makeName(name, .store);
            try pending.names.append(self.stack_alloc, target);
            if (pending.remain > 0) pending.remain -= 1;
            if (pending.remain == 0) {
                const a = self.allocator;
                const elts = try a.alloc(*Expr, pending.names.items.len);
                std.mem.copyForwards(*Expr, elts, pending.names.items);
                const tuple = try ast.makeTuple(a, elts, .store);
                try self.addCompTarget(pending.builder, tuple);
                pending.names.deinit(self.stack_alloc);
                self.comp_unpack = null;
            }
            return true;
        }
        return false;
    }

    fn makeIsNoneCompare(self: *SimContext, value: *Expr, is_not: bool) !*Expr {
        const none_expr = try ast.makeConstant(self.allocator, .none);
        errdefer {
            none_expr.deinit(self.allocator);
            self.allocator.destroy(none_expr);
        }

        const comparators = try self.allocator.alloc(*Expr, 1);
        errdefer self.allocator.free(comparators);
        comparators[0] = none_expr;

        const ops = try self.allocator.alloc(ast.CmpOp, 1);
        errdefer self.allocator.free(ops);
        ops[0] = if (is_not) .is_not else .is;

        const expr = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(expr);
        expr.* = .{ .compare = .{
            .left = value,
            .ops = ops,
            .comparators = comparators,
        } };
        return expr;
    }

    fn buildCompExpr(self: *SimContext, builder: *CompBuilder) SimError!*Expr {
        if (builder.generators.items.len == 0) return error.InvalidComprehension;

        const gens = try self.allocator.alloc(ast.Comprehension, builder.generators.items.len);
        var built: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < built) : (i += 1) {
                gens[i].target.deinit(self.allocator);
                self.allocator.destroy(gens[i].target);
                gens[i].iter.deinit(self.allocator);
                self.allocator.destroy(gens[i].iter);
                for (gens[i].ifs) |cond| {
                    cond.deinit(self.allocator);
                    self.allocator.destroy(cond);
                }
                if (gens[i].ifs.len > 0) self.allocator.free(gens[i].ifs);
            }
            self.allocator.free(gens);
        }

        for (builder.generators.items, 0..) |*gen, idx| {
            const target = gen.target orelse return error.InvalidComprehension;
            const iter_expr = gen.iter orelse return error.InvalidComprehension;
            const ifs = try gen.ifs.toOwnedSlice(self.allocator);

            gens[idx] = .{
                .target = target,
                .iter = iter_expr,
                .ifs = ifs,
                .is_async = gen.is_async,
            };
            built += 1;

            gen.target = null;
            gen.iter = null;
        }

        builder.generators.items.len = 0;
        builder.loop_stack.items.len = 0;

        const expr = try self.allocator.create(Expr);
        errdefer self.allocator.destroy(expr);

        switch (builder.kind) {
            .list => {
                const elt = builder.elt orelse return error.InvalidComprehension;
                builder.elt = null;
                expr.* = .{ .list_comp = .{ .elt = elt, .generators = gens } };
            },
            .set => {
                const elt = builder.elt orelse return error.InvalidComprehension;
                builder.elt = null;
                expr.* = .{ .set_comp = .{ .elt = elt, .generators = gens } };
            },
            .dict => {
                const key = builder.key orelse return error.InvalidComprehension;
                const value = builder.value orelse return error.InvalidComprehension;
                builder.key = null;
                builder.value = null;
                expr.* = .{ .dict_comp = .{
                    .key = key,
                    .value = value,
                    .generators = gens,
                } };
            },
            .genexpr => {
                const elt = builder.elt orelse return error.InvalidComprehension;
                builder.elt = null;
                expr.* = .{ .generator_exp = .{ .elt = elt, .generators = gens } };
            },
        }

        return expr;
    }

    pub fn buildInlineCompExpr(self: *SimContext) SimError!?*Expr {
        const builder = self.findActiveCompBuilder() orelse return null;
        if (!builder.seen_append) return null;
        return self.buildCompExpr(builder);
    }

    fn buildComprehensionFromCode(self: *SimContext, comp: CompObject, iter_expr: *Expr) SimError!*Expr {
        var nested = SimContext.init(self.allocator, self.stack_alloc, comp.code, self.version);
        defer nested.deinit();
        nested.enable_ifexp = true;

        const builder = try self.stack_alloc.create(CompBuilder);
        builder.* = CompBuilder.init(comp.kind);
        errdefer builder.deinit(self.allocator, self.stack_alloc);

        nested.comp_builder = builder;
        nested.iter_override = .{ .index = 0, .expr = iter_expr };

        var pending: std.ArrayListUnmanaged(PendingBoolOp) = .{};
        defer pending.deinit(self.allocator);

        var iter = decoder.InstructionIterator.init(comp.code.code, self.version);
        while (iter.next()) |inst| {
            _ = try resolveBoolOps(self.allocator, &nested.stack, &pending, inst.offset);
            _ = try resolveIfExps(self.allocator, &nested.stack, &nested.pending_ifexp, inst.offset);
            switch (inst.opcode) {
                .RETURN_VALUE,
                .RETURN_CONST,
                // Loop epilogue that doesn't affect the comprehension AST shape.
                // Avoid simulating cleanup ops that depend on branch-sensitive stack effects.
                .END_FOR,
                .END_ASYNC_FOR,
                .POP_ITER,
                => break,
                .JUMP_IF_FALSE_OR_POP => {
                    const left = try nested.stack.popExpr();
                    var chain_compare = false;
                    if (left.* == .compare and left.compare.comparators.len > 0) {
                        if (nested.stack.peek()) |val| {
                            if (val == .expr and ast.exprEqual(val.expr, left.compare.comparators[left.compare.comparators.len - 1])) {
                                chain_compare = true;
                            }
                        }
                    }
                    try pending.append(self.allocator, .{
                        .target = inst.arg,
                        .op = .and_,
                        .left = left,
                        .chain_compare = chain_compare,
                    });
                    continue;
                },
                .JUMP_IF_TRUE_OR_POP => {
                    const left = try nested.stack.popExpr();
                    try pending.append(self.allocator, .{
                        .target = inst.arg,
                        .op = .or_,
                        .left = left,
                        .chain_compare = false,
                    });
                    continue;
                },
                else => try nested.simulate(inst),
            }
        }

        if (!builder.seen_append) return error.InvalidComprehension;
        const expr = try nested.buildCompExpr(builder);
        nested.comp_builder = null;
        builder.deinit(self.allocator, self.stack_alloc);
        return expr;
    }

    /// Simulate a single instruction.
    pub fn simulate(self: *SimContext, inst: Instruction) SimError!void {
        if (self.enable_ifexp) {
            _ = try resolveIfExps(self.allocator, &self.stack, &self.pending_ifexp, inst.offset);
        }
        switch (inst.opcode) {
            .NOP,
            .RESUME,
            .CACHE,
            .EXTENDED_ARG,
            .NOT_TAKEN,
            .SETUP_LOOP,
            .SETUP_EXCEPT,
            .POP_BLOCK,
            .SET_LINENO,
            .JUMP_BACKWARD,
            .JUMP_BACKWARD_NO_INTERRUPT,
            .JUMP_ABSOLUTE,
            .CONTINUE_LOOP,
            .BREAK_LOOP,
            => {
                // No stack effect
            },

            .JUMP_FORWARD => {
                if (self.enable_ifexp) {
                    const target = inst.jumpTarget(self.version) orelse inst.arg;
                    if (try captureIfExpThen(&self.stack, &self.pending_ifexp, inst.offset, target)) return;
                }
                // No stack effect
            },

            .RETURN_GENERATOR => {
                // Push a placeholder generator value (popped by POP_TOP in genexpr prologue)
                try self.stack.push(.unknown);
            },

            .POP_TOP => {
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
            },

            .PUSH_NULL => {
                try self.stack.push(.null_marker);
            },

            .LOAD_CONST => {
                if (self.getConst(inst.arg)) |obj| {
                    switch (obj) {
                        .code, .code_ref => |code| {
                            try self.stack.push(.{ .code_obj = code });
                        },
                        else => {
                            if (isConstObj(obj)) {
                                const constant = try self.objToConstant(obj);
                                const expr = try ast.makeConstant(self.allocator, constant);
                                try self.stack.push(.{ .expr = expr });
                            } else {
                                const expr = try self.objToExpr(obj);
                                try self.stack.push(.{ .expr = expr });
                            }
                        },
                    }
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .LOAD_ASSERTION_ERROR => {
                const expr = try self.makeName("AssertionError", .load);
                try self.stack.push(.{ .expr = expr });
            },

            .LOAD_COMMON_CONSTANT => {
                if (inst.arg == 0) {
                    const expr = try self.makeName("AssertionError", .load);
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
                const name_idx = if (inst.opcode == .LOAD_GLOBAL and self.version.gte(3, 11))
                    inst.arg >> 1
                else
                    inst.arg;
                const push_null = inst.opcode == .LOAD_GLOBAL and self.version.gte(3, 11) and (inst.arg & 1) == 1;
                // In 3.11+: push NULL BEFORE callable for call preparation
                // Stack order: [NULL/self, callable, args...] from bottom to top
                if (push_null) try self.stack.push(.null_marker);
                if (self.getName(name_idx)) |name| {
                    const expr = try self.makeName(name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .LOAD_FAST, .LOAD_FAST_CHECK, .LOAD_FAST_BORROW => {
                if (self.iter_override) |*ov| {
                    if (inst.arg == ov.index) {
                        if (ov.expr) |expr| {
                            ov.expr = null;
                            try self.stack.push(.{ .expr = expr });
                            return;
                        }
                    }
                }

                if (self.getLocal(inst.arg)) |name| {
                    const expr = try self.makeName(name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .LOAD_FAST_AND_CLEAR => {
                if (self.getLocal(inst.arg)) |name| {
                    try self.stack.push(.{ .saved_local = name });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .LOAD_FAST_LOAD_FAST, .LOAD_FAST_BORROW_LOAD_FAST_BORROW => {
                // Combined instruction that loads two fast variables
                // arg encodes two 4-bit indices: first in high nibble, second in low nibble
                // For arg=0x12: first_idx=1, second_idx=2
                const first_idx = (inst.arg >> 4) & 0xF;
                const second_idx = inst.arg & 0xF;

                // Push first variable
                if (self.getLocal(first_idx)) |name| {
                    const expr = try self.makeName(name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }

                // Push second variable
                if (self.getLocal(second_idx)) |name| {
                    const expr = try self.makeName(name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .STORE_NAME, .STORE_GLOBAL => {
                // Check for walrus operator: COPY 1 followed by STORE_* in comprehension
                const is_walrus = self.prev_opcode == .COPY and self.findActiveCompBuilder() != null;
                if (is_walrus) {
                    // Walrus operator: (name := value)
                    // After COPY 1: stack is [value, value_copy]
                    // STORE pops value_copy, we transform remaining value to named_expr
                    if (self.stack.pop()) |copy| {
                        var c = copy;
                        c.deinit(self.allocator, self.stack_alloc);
                    }
                    // Transform TOS to named_expr
                    if (self.stack.pop()) |val| {
                        const name = self.getName(inst.arg) orelse "__unknown__";
                        const target = try self.makeName(name, .store);
                        errdefer {
                            target.deinit(self.allocator);
                            self.allocator.destroy(target);
                        }
                        const value_expr = switch (val) {
                            .expr => |e| e,
                            else => blk: {
                                var v = val;
                                v.deinit(self.allocator, self.stack_alloc);
                                break :blk try self.makeName("__unknown__", .load);
                            },
                        };
                        const named = try self.allocator.create(Expr);
                        named.* = .{ .named_expr = .{ .target = target, .value = value_expr } };
                        try self.stack.push(.{ .expr = named });
                    }
                } else {
                    // Normal store - pop the value
                    if (self.stack.pop()) |v| {
                        const name = self.getName(inst.arg) orelse "__unknown__";
                        if (!try self.consumeCompUnpackName(name)) {
                            try self.addCompTargetName(name);
                        }
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    }
                }
            },

            .STORE_ANNOTATION => {
                // STORE_ANNOTATION namei - stores annotation, value is on stack
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
            },

            .STORE_FAST => {
                // Check for walrus operator: COPY 1 followed by STORE_FAST in comprehension
                const is_walrus = self.prev_opcode == .COPY and self.findActiveCompBuilder() != null;
                if (is_walrus) {
                    // Walrus operator: (name := value)
                    if (self.stack.pop()) |copy| {
                        var c = copy;
                        c.deinit(self.allocator, self.stack_alloc);
                    }
                    if (self.stack.pop()) |val| {
                        const name = self.getLocal(inst.arg) orelse "__unknown__";
                        const target = try self.makeName(name, .store);
                        errdefer {
                            target.deinit(self.allocator);
                            self.allocator.destroy(target);
                        }
                        const value_expr = switch (val) {
                            .expr => |e| e,
                            else => blk: {
                                var v = val;
                                v.deinit(self.allocator, self.stack_alloc);
                                break :blk try self.makeName("__unknown__", .load);
                            },
                        };
                        const named = try self.allocator.create(Expr);
                        named.* = .{ .named_expr = .{ .target = target, .value = value_expr } };
                        try self.stack.push(.{ .expr = named });
                    }
                } else {
                    // Normal store - pop the value
                    if (self.stack.pop()) |v| {
                        const name = self.getLocal(inst.arg) orelse "__unknown__";
                        if (!try self.consumeCompUnpackName(name)) {
                            try self.addCompTargetName(name);
                        }
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    }
                }
            },

            .STORE_FAST_LOAD_FAST => {
                // STORE_FAST_LOAD_FAST - store TOS into local and then push it back
                // Used in match statements: COPY 1, STORE_FAST_LOAD_FAST stores subject and loads pattern var
                const val = if (self.stack.pop()) |v| v else return error.StackUnderflow;
                const store_idx = (inst.arg >> 4) & 0xF;
                const load_idx = inst.arg & 0xF;

                // Store the popped value into store_idx local
                if (self.getLocal(store_idx)) |store_name| {
                    if (self.findActiveCompBuilder()) |builder| {
                        const target = try self.makeName(store_name, .store);
                        try self.addCompTarget(builder, target);
                    }
                }

                // Deinit the value after storing
                val.deinit(self.allocator, self.stack_alloc);

                // Load from load_idx and push to stack
                if (self.getLocal(load_idx)) |name| {
                    const expr = try self.makeName(name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .STORE_FAST_STORE_FAST => {
                // STORE_FAST_STORE_FAST - store TOS into local1 then TOS into local2
                // arg packs indices in 4-bit nibbles: (hi=idx1, lo=idx2)
                // Pops two values from stack
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
            },

            .BINARY_OP => {
                // Pop two operands
                const right = try self.stack.popExpr();
                errdefer {
                    right.deinit(self.allocator);
                    self.allocator.destroy(right);
                }
                const left = try self.stack.popExpr();
                errdefer {
                    left.deinit(self.allocator);
                    self.allocator.destroy(left);
                }

                // BINARY_OP arg 26 is NB_SUBSCR (subscript operation)
                if (inst.arg == 26) {
                    const expr = try self.allocator.create(Expr);
                    expr.* = .{ .subscript = .{
                        .value = left,
                        .slice = right,
                        .ctx = .load,
                    } };
                    try self.stack.push(.{ .expr = expr });
                } else {
                    const op = binOpFromArg(inst.arg);
                    const expr = try ast.makeBinOp(self.allocator, left, op, right);
                    try self.stack.push(.{ .expr = expr });
                    if (inst.arg >= 13 and inst.arg <= 25) {
                        try self.markInplaceExpr(expr);
                    }
                }
            },

            // Legacy binary operators (Python < 3.11)
            .BINARY_ADD,
            .BINARY_SUBTRACT,
            .BINARY_MULTIPLY,
            .BINARY_MODULO,
            .BINARY_POWER,
            .BINARY_DIVIDE,
            .BINARY_TRUE_DIVIDE,
            .BINARY_FLOOR_DIVIDE,
            .BINARY_LSHIFT,
            .BINARY_RSHIFT,
            .BINARY_AND,
            .BINARY_XOR,
            .BINARY_OR,
            .BINARY_MATRIX_MULTIPLY,
            // Inplace variants (for augmented assignment)
            .INPLACE_ADD,
            .INPLACE_SUBTRACT,
            .INPLACE_MULTIPLY,
            .INPLACE_MODULO,
            .INPLACE_POWER,
            .INPLACE_TRUE_DIVIDE,
            .INPLACE_FLOOR_DIVIDE,
            .INPLACE_LSHIFT,
            .INPLACE_RSHIFT,
            .INPLACE_AND,
            .INPLACE_XOR,
            .INPLACE_OR,
            .INPLACE_MATRIX_MULTIPLY,
            .INPLACE_DIVIDE,
            => {
                const right = try self.stack.popExpr();
                errdefer {
                    right.deinit(self.allocator);
                    self.allocator.destroy(right);
                }
                const left = try self.stack.popExpr();
                errdefer {
                    left.deinit(self.allocator);
                    self.allocator.destroy(left);
                }
                const op: ast.BinOp = switch (inst.opcode) {
                    .BINARY_ADD, .INPLACE_ADD => .add,
                    .BINARY_SUBTRACT, .INPLACE_SUBTRACT => .sub,
                    .BINARY_MULTIPLY, .INPLACE_MULTIPLY => .mult,
                    .BINARY_MODULO, .INPLACE_MODULO => .mod,
                    .BINARY_POWER, .INPLACE_POWER => .pow,
                    .BINARY_DIVIDE, .BINARY_TRUE_DIVIDE, .INPLACE_TRUE_DIVIDE => .div,
                    .BINARY_FLOOR_DIVIDE, .INPLACE_FLOOR_DIVIDE => .floordiv,
                    .BINARY_LSHIFT, .INPLACE_LSHIFT => .lshift,
                    .BINARY_RSHIFT, .INPLACE_RSHIFT => .rshift,
                    .BINARY_AND, .INPLACE_AND => .bitand,
                    .BINARY_XOR, .INPLACE_XOR => .bitxor,
                    .BINARY_OR, .INPLACE_OR => .bitor,
                    .BINARY_MATRIX_MULTIPLY, .INPLACE_MATRIX_MULTIPLY => .matmult,
                    .INPLACE_DIVIDE => .div,
                    else => unreachable,
                };
                const expr = try ast.makeBinOp(self.allocator, left, op, right);
                try self.stack.push(.{ .expr = expr });
                if (inst.opcode == .INPLACE_ADD or
                    inst.opcode == .INPLACE_SUBTRACT or
                    inst.opcode == .INPLACE_MULTIPLY or
                    inst.opcode == .INPLACE_MODULO or
                    inst.opcode == .INPLACE_POWER or
                    inst.opcode == .INPLACE_TRUE_DIVIDE or
                    inst.opcode == .INPLACE_FLOOR_DIVIDE or
                    inst.opcode == .INPLACE_LSHIFT or
                    inst.opcode == .INPLACE_RSHIFT or
                    inst.opcode == .INPLACE_AND or
                    inst.opcode == .INPLACE_XOR or
                    inst.opcode == .INPLACE_OR or
                    inst.opcode == .INPLACE_MATRIX_MULTIPLY or
                    inst.opcode == .INPLACE_DIVIDE)
                {
                    try self.markInplaceExpr(expr);
                }
            },

            .COMPARE_OP => {
                // Pop two operands, create Compare expression
                const right = try self.stack.popExpr();
                errdefer {
                    right.deinit(self.allocator);
                    self.allocator.destroy(right);
                }
                const left = try self.stack.popExpr();
                errdefer {
                    left.deinit(self.allocator);
                    self.allocator.destroy(left);
                }

                // Create a compare expression
                const comparators = try self.allocator.alloc(*Expr, 1);
                errdefer self.allocator.free(comparators);
                comparators[0] = right;
                const ops = try self.allocator.alloc(ast.CmpOp, 1);
                errdefer self.allocator.free(ops);
                ops[0] = cmpOpFromArg(inst.arg, self.version);

                const expr = try self.allocator.create(Expr);
                errdefer self.allocator.destroy(expr);
                expr.* = .{ .compare = .{
                    .left = left,
                    .ops = ops,
                    .comparators = comparators,
                } };
                try self.stack.push(.{ .expr = expr });
            },

            // Python 3.9+ identity and membership operators
            .IS_OP => {
                const right = try self.stack.popExpr();
                const left = try self.stack.popExpr();

                const comparators = try self.allocator.alloc(*Expr, 1);
                comparators[0] = right;
                const ops = try self.allocator.alloc(ast.CmpOp, 1);
                // IS_OP 0 = is, IS_OP 1 = is not
                ops[0] = if (inst.arg == 0) .is else .is_not;

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .compare = .{
                    .left = left,
                    .ops = ops,
                    .comparators = comparators,
                } };
                try self.stack.push(.{ .expr = expr });
            },

            .CONTAINS_OP => {
                // Stack: [..., sequence, item] -> [..., result]
                // CONTAINS_OP 0 = item in sequence
                // CONTAINS_OP 1 = item not in sequence
                var sequence = try self.stack.popExpr();
                const item = try self.stack.popExpr();

                if (sequence.* == .call) {
                    const call = sequence.call;
                    if (call.func.* == .name and std.mem.eql(u8, call.func.name.id, "frozenset") and call.args.len == 1) {
                        const arg0 = call.args[0];
                        switch (arg0.*) {
                            .list => |*l| {
                                const elts = l.elts;
                                l.elts = &.{};
                                sequence.deinit(self.allocator);
                                self.allocator.destroy(sequence);
                                const set_expr = try self.allocator.create(Expr);
                                set_expr.* = .{ .set = .{ .elts = elts, .cap = elts.len } };
                                sequence = set_expr;
                            },
                            .tuple => |*t| {
                                const elts = t.elts;
                                t.elts = &.{};
                                sequence.deinit(self.allocator);
                                self.allocator.destroy(sequence);
                                const set_expr = try self.allocator.create(Expr);
                                set_expr.* = .{ .set = .{ .elts = elts, .cap = elts.len } };
                                sequence = set_expr;
                            },
                            .set => |*s| {
                                const elts = s.elts;
                                s.elts = &.{};
                                s.cap = 0;
                                sequence.deinit(self.allocator);
                                self.allocator.destroy(sequence);
                                const set_expr = try self.allocator.create(Expr);
                                set_expr.* = .{ .set = .{ .elts = elts, .cap = elts.len } };
                                sequence = set_expr;
                            },
                            else => {},
                        }
                    }
                }

                const comparators = try self.allocator.alloc(*Expr, 1);
                comparators[0] = sequence;
                const ops = try self.allocator.alloc(ast.CmpOp, 1);
                ops[0] = if (inst.arg == 0) .in_ else .not_in;

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .compare = .{
                    .left = item,
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

            .BUILD_LIST_UNPACK => {
                try self.buildStarredSequence(.list, inst.arg);
            },

            .BUILD_TUPLE => {
                const count = inst.arg;
                if (count == 0) {
                    const expr = try ast.makeTuple(self.allocator, &.{}, .load);
                    errdefer {
                        expr.deinit(self.allocator);
                        self.allocator.destroy(expr);
                    }
                    try self.empty_tuple_builds.put(self.stack_alloc, expr, true);
                    errdefer _ = self.empty_tuple_builds.remove(expr);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    // Try to pop as expressions; if any are unknown (e.g., closure cells),
                    // push unknown since this is likely a closure tuple for MAKE_CLOSURE
                    const elts = self.stack.popNExprs(count) catch |err| {
                        if (err == error.NotAnExpression) {
                            // popNExprs already consumed the values
                            try self.stack.push(.unknown);
                            return;
                        }
                        return err;
                    };
                    const expr = try ast.makeTuple(self.allocator, elts, .load);
                    try self.stack.push(.{ .expr = expr });
                }
            },

            .BUILD_TUPLE_UNPACK, .BUILD_TUPLE_UNPACK_WITH_CALL => {
                try self.buildStarredSequence(.tuple, inst.arg);
            },

            .BUILD_SET => {
                const count = inst.arg;
                const elts = if (count == 0) &[_]*Expr{} else try self.stack.popNExprs(count);
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .set = .{ .elts = elts, .cap = elts.len } };
                try self.stack.push(.{ .expr = expr });
            },

            .BUILD_SET_UNPACK => {
                try self.buildStarredSequence(.set, inst.arg);
            },

            .LIST_TO_TUPLE => {
                const value = try self.stack.popExpr();
                if (value.* == .list) {
                    const elts = value.list.elts;
                    value.list.elts = &.{};
                    value.deinit(self.allocator);
                    self.allocator.destroy(value);
                    const expr = try ast.makeTuple(self.allocator, elts, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    errdefer {
                        value.deinit(self.allocator);
                        self.allocator.destroy(value);
                    }
                    const func = try self.makeName("tuple", .load);
                    errdefer {
                        func.deinit(self.allocator);
                        self.allocator.destroy(func);
                    }
                    const args = try self.allocator.alloc(*Expr, 1);
                    args[0] = value;
                    const expr = try ast.makeCall(self.allocator, func, args);
                    try self.stack.push(.{ .expr = expr });
                }
            },

            .KW_NAMES => {
                // KW_NAMES arg - sets keyword names for following CALL (3.11+)
                // arg is index into co_consts for tuple of keyword name strings
                if (self.getConst(inst.arg)) |obj| {
                    if (obj == .tuple) {
                        const tuple = obj.tuple;
                        const names = try self.allocator.alloc([]const u8, tuple.len);
                        for (tuple, 0..) |elem, i| {
                            if (elem == .string) {
                                names[i] = elem.string;
                            } else {
                                names[i] = "__unknown__";
                            }
                        }
                        self.pending_kwnames = names;
                    }
                }
            },

            .PRECALL => {
                // PRECALL - no-op in 3.11, removed in 3.12
                // Used for specialization hints, no stack effect
            },

            .CALL => {
                // In 3.11+: Two calling conventions:
                // 1. With PUSH_NULL: stack is [NULL/self, callable, args...]
                // 2. Comprehension: stack is [callable, iter_arg] (no NULL, argc=0)
                const argc = inst.arg;
                const args_vals = try self.stack.popN(argc);

                // Peek at top two values to determine calling convention
                // For normal calls: [NULL, callable] with callable on top
                // For comprehension: [callable, iter] with iter on top
                const tos = self.stack.pop() orelse {
                    self.deinitStackValues(args_vals);
                    return error.StackUnderflow;
                };

                const tos1 = self.stack.pop() orelse {
                    tos.deinit(self.allocator, self.stack_alloc);
                    self.deinitStackValues(args_vals);
                    return error.StackUnderflow;
                };

                var callable: StackValue = undefined;
                var iter_expr_from_stack: ?*Expr = null;

                // Detect comprehension call: TOS-1 is comp_obj/function_obj, TOS is expr (iterator)
                const is_comp_call = argc == 0 and
                    (tos1 == .comp_obj or tos1 == .function_obj) and
                    tos == .expr;

                // Detect decorator application: decorator(function)
                // Stack: [decorator_expr, function_obj], argc=0
                const is_decorator_call = argc == 0 and
                    tos1 == .expr and
                    tos == .function_obj;

                if (is_comp_call) {
                    // Comprehension call: gen_func(iter_expr) without PUSH_NULL
                    // Stack was [callable, iter_expr] with iter_expr on top
                    callable = tos1;
                    iter_expr_from_stack = tos.expr;
                    try self.handleCall(callable, args_vals, &[_]ast.Keyword{}, iter_expr_from_stack);
                } else if (is_decorator_call) {
                    // Decorator application: decorator(function)
                    // Attach decorator to the function object and push it back
                    const decorator = tos1.expr;
                    try tos.function_obj.decorators.insert(self.allocator, 0, decorator);
                    self.stack.releasePop(args_vals);
                    try self.stack.push(tos);
                } else {
                    callable = try self.resolveCallTarget(tos, tos1);

                    // Check if KW_NAMES set up keyword argument names
                    if (self.pending_kwnames) |kwnames| {
                        defer {
                            self.allocator.free(kwnames);
                            self.pending_kwnames = null;
                        }
                        const split = try self.buildPosArgsAndKeywords(args_vals, kwnames);
                        try self.handleCall(callable, split.posargs, split.keywords, iter_expr_from_stack);
                    } else {
                        try self.handleCall(callable, args_vals, &[_]ast.Keyword{}, iter_expr_from_stack);
                    }
                }
            },

            .CALL_KW => {
                // CALL_KW argc - call with kwargs
                // Stack: callable, posargs..., kwvalues..., kwnames_tuple
                const argc = inst.arg;

                // Pop kwnames tuple
                const kwnames_val = self.stack.pop() orelse return error.StackUnderflow;
                defer kwnames_val.deinit(self.allocator, self.stack_alloc);

                var kwnames: []const []const u8 = &.{};
                if (kwnames_val == .expr and kwnames_val.expr.* == .tuple) {
                    const tuple_elts = kwnames_val.expr.tuple.elts;
                    const names = try self.allocator.alloc([]const u8, tuple_elts.len);
                    for (tuple_elts, 0..) |elt, i| {
                        if (elt.* == .constant and elt.constant == .string) {
                            names[i] = elt.constant.string;
                        } else {
                            names[i] = "__unknown__";
                        }
                    }
                    kwnames = names;
                }
                defer if (kwnames.len > 0) self.allocator.free(kwnames);

                // Pop all args (positional + keyword values)
                const all_vals = try self.stack.popN(argc);
                errdefer self.deinitStackValues(all_vals);

                const tos = self.stack.pop() orelse return error.StackUnderflow;
                const tos1 = self.stack.pop() orelse {
                    tos.deinit(self.allocator, self.stack_alloc);
                    return error.StackUnderflow;
                };
                const callable = try self.resolveCallTarget(tos, tos1);

                const split = try self.buildPosArgsAndKeywords(all_vals, kwnames);
                try self.handleCall(callable, split.posargs, split.keywords, null);
            },

            .CALL_METHOD => {
                // 3.7-3.10: CALL_METHOD argc
                // Stack: NULL/self, method, args... -> result
                const argc = inst.arg;
                var args_vals = try self.stack.popN(argc);
                // Pop method (callable)
                const callable = self.stack.pop() orelse {
                    self.deinitStackValues(args_vals);
                    return error.StackUnderflow;
                };
                // Pop NULL/self marker
                const marker = self.stack.pop() orelse {
                    var val = callable;
                    val.deinit(self.allocator, self.stack_alloc);
                    self.deinitStackValues(args_vals);
                    return error.StackUnderflow;
                };
                // If marker is self (an expr), prepend it to args
                if (marker == .expr) {
                    const expr = marker.expr;
                    const args_with_self = self.stack_alloc.alloc(StackValue, args_vals.len + 1) catch |err| {
                        expr.deinit(self.allocator);
                        self.allocator.destroy(expr);
                        var val = callable;
                        val.deinit(self.allocator, self.stack_alloc);
                        self.deinitStackValues(args_vals);
                        return err;
                    };
                    args_with_self[0] = .{ .expr = expr };
                    @memcpy(args_with_self[1..], args_vals);
                    self.stack.releasePop(args_vals);
                    args_vals = args_with_self;
                } else if (marker != .null_marker) {
                    var val = marker;
                    val.deinit(self.allocator, self.stack_alloc);
                }
                try self.handleCall(callable, args_vals, &[_]ast.Keyword{}, null);
            },

            .CALL_FUNCTION => {
                if (self.flow_mode) {
                    var argc_flow: usize = if (self.version.lt(3, 6))
                        @intCast((inst.arg & 0xFF) + (((inst.arg >> 8) & 0xFF) * 2))
                    else
                        @intCast(inst.arg);
                    while (argc_flow > 0) : (argc_flow -= 1) {
                        if (self.stack.pop()) |v| {
                            var val = v;
                            val.deinit(self.allocator, self.stack_alloc);
                        } else return error.StackUnderflow;
                    }
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    } else return error.StackUnderflow;
                    try self.stack.push(.unknown);
                    return;
                }
                if (self.version.lt(3, 6)) {
                    const num_pos: usize = @intCast(inst.arg & 0xFF);
                    const num_kw: usize = @intCast((inst.arg >> 8) & 0xFF);

                    var keywords: []ast.Keyword = &.{};
                    if (num_kw > 0) {
                        keywords = try self.allocator.alloc(ast.Keyword, num_kw);
                    }
                    var kw_filled: usize = 0;
                    errdefer {
                        for (keywords[0..kw_filled]) |kw| {
                            if (kw.arg) |arg| self.allocator.free(arg);
                            kw.value.deinit(self.allocator);
                            self.allocator.destroy(kw.value);
                        }
                        if (num_kw > 0) self.allocator.free(keywords);
                    }

                    var kw_idx = num_kw;
                    while (kw_idx > 0) : (kw_idx -= 1) {
                        const value = try self.stack.popExpr();
                        var value_owned = true;
                        errdefer if (value_owned) {
                            value.deinit(self.allocator);
                            self.allocator.destroy(value);
                        };
                        const name_val = self.stack.pop() orelse return error.StackUnderflow;
                        const name = try self.keywordNameFromValue(name_val);
                        keywords[kw_idx - 1] = .{ .arg = name, .value = value };
                        kw_filled += 1;
                        value_owned = false;
                    }

                    const args_vals = try self.stack.popN(num_pos);
                    var args_owned = true;
                    errdefer if (args_owned) self.deinitStackValues(args_vals);

                    const callable = self.stack.pop() orelse {
                        self.deinitStackValues(args_vals);
                        return error.StackUnderflow;
                    };
                    args_owned = false;

                    try self.handleCall(callable, args_vals, keywords, null);
                } else {
                    const argc = inst.arg;
                    const args_vals = try self.stack.popN(argc);
                    const callable = self.stack.pop() orelse {
                        self.deinitStackValues(args_vals);
                        return error.StackUnderflow;
                    };
                    try self.handleCall(callable, args_vals, &[_]ast.Keyword{}, null);
                }
            },

            .CALL_FUNCTION_VAR => {
                const num_pos: usize = @intCast(inst.arg & 0xFF);
                const num_kw: usize = @intCast((inst.arg >> 8) & 0xFF);

                const star_val = self.stack.pop() orelse return error.StackUnderflow;
                const star_expr = switch (star_val) {
                    .expr => |expr| expr,
                    else => {
                        var val = star_val;
                        val.deinit(self.allocator, self.stack_alloc);
                        return error.NotAnExpression;
                    },
                };

                const starred_arg = if (star_expr.* == .starred)
                    star_expr
                else blk: {
                    errdefer {
                        star_expr.deinit(self.allocator);
                        self.allocator.destroy(star_expr);
                    }
                    break :blk try ast.makeStarred(self.allocator, star_expr, .load);
                };
                var star_owned = true;
                errdefer if (star_owned) {
                    starred_arg.deinit(self.allocator);
                    self.allocator.destroy(starred_arg);
                };

                var keywords: []ast.Keyword = &.{};
                if (num_kw > 0) {
                    keywords = try self.allocator.alloc(ast.Keyword, num_kw);
                }
                var kw_filled: usize = 0;
                errdefer {
                    for (keywords[0..kw_filled]) |kw| {
                        if (kw.arg) |arg| self.allocator.free(arg);
                        kw.value.deinit(self.allocator);
                        self.allocator.destroy(kw.value);
                    }
                    if (num_kw > 0) self.allocator.free(keywords);
                }

                var kw_idx = num_kw;
                while (kw_idx > 0) : (kw_idx -= 1) {
                    const value = try self.stack.popExpr();
                    var value_owned = true;
                    errdefer if (value_owned) {
                        value.deinit(self.allocator);
                        self.allocator.destroy(value);
                    };
                    const name_val = self.stack.pop() orelse return error.StackUnderflow;
                    const name = try self.keywordNameFromValue(name_val);
                    keywords[kw_idx - 1] = .{ .arg = name, .value = value };
                    kw_filled += 1;
                    value_owned = false;
                }

                const pos_vals = try self.stack.popN(num_pos);
                var pos_owned = true;
                errdefer if (pos_owned) self.deinitStackValues(pos_vals);

                const pos_exprs = try self.stack.valuesToExprs(pos_vals);
                pos_owned = false;
                var pos_exprs_owned = true;
                errdefer if (pos_exprs_owned) {
                    for (pos_exprs) |arg| {
                        arg.deinit(self.allocator);
                        self.allocator.destroy(arg);
                    }
                    self.allocator.free(pos_exprs);
                };

                const args = try self.allocator.alloc(*Expr, pos_exprs.len + 1);
                errdefer {
                    for (args) |arg| {
                        arg.deinit(self.allocator);
                        self.allocator.destroy(arg);
                    }
                    self.allocator.free(args);
                }
                @memcpy(args[0..pos_exprs.len], pos_exprs);
                args[pos_exprs.len] = starred_arg;
                star_owned = false;
                pos_exprs_owned = false;
                self.allocator.free(pos_exprs);

                const callable = self.stack.pop() orelse return error.StackUnderflow;
                switch (callable) {
                    .expr => |callee_expr| {
                        var cleanup_callee = true;
                        errdefer if (cleanup_callee) {
                            callee_expr.deinit(self.allocator);
                            self.allocator.destroy(callee_expr);
                        };
                        const call_expr = try ast.makeCallWithKeywords(self.allocator, callee_expr, args, keywords);
                        errdefer {
                            call_expr.deinit(self.allocator);
                            self.allocator.destroy(call_expr);
                        }
                        try self.stack.push(.{ .expr = call_expr });
                        cleanup_callee = false;
                    },
                    else => {
                        var val = callable;
                        val.deinit(self.allocator, self.stack_alloc);
                        return error.NotAnExpression;
                    },
                }
            },

            .CALL_FUNCTION_VAR_KW => {
                const num_pos: usize = @intCast(inst.arg & 0xFF);
                const num_kw: usize = @intCast((inst.arg >> 8) & 0xFF);

                const kwargs_val = self.stack.pop() orelse return error.StackUnderflow;
                const kwargs_expr = switch (kwargs_val) {
                    .expr => |expr| expr,
                    else => {
                        var val = kwargs_val;
                        val.deinit(self.allocator, self.stack_alloc);
                        return error.NotAnExpression;
                    },
                };
                var kwargs_owned = true;
                errdefer if (kwargs_owned) {
                    kwargs_expr.deinit(self.allocator);
                    self.allocator.destroy(kwargs_expr);
                };

                const star_val = self.stack.pop() orelse return error.StackUnderflow;
                const star_expr = switch (star_val) {
                    .expr => |expr| expr,
                    else => {
                        var val = star_val;
                        val.deinit(self.allocator, self.stack_alloc);
                        return error.NotAnExpression;
                    },
                };

                const starred_arg = if (star_expr.* == .starred)
                    star_expr
                else blk: {
                    errdefer {
                        star_expr.deinit(self.allocator);
                        self.allocator.destroy(star_expr);
                    }
                    break :blk try ast.makeStarred(self.allocator, star_expr, .load);
                };
                var star_owned = true;
                errdefer if (star_owned) {
                    starred_arg.deinit(self.allocator);
                    self.allocator.destroy(starred_arg);
                };

                var keywords = try self.allocator.alloc(ast.Keyword, num_kw + 1);
                var kw_filled: usize = 0;
                errdefer {
                    for (keywords[0..kw_filled]) |kw| {
                        if (kw.arg) |arg| self.allocator.free(arg);
                        kw.value.deinit(self.allocator);
                        self.allocator.destroy(kw.value);
                    }
                    self.allocator.free(keywords);
                }

                var kw_idx = num_kw;
                while (kw_idx > 0) : (kw_idx -= 1) {
                    const value = try self.stack.popExpr();
                    var value_owned = true;
                    errdefer if (value_owned) {
                        value.deinit(self.allocator);
                        self.allocator.destroy(value);
                    };
                    const name_val = self.stack.pop() orelse return error.StackUnderflow;
                    const name = try self.keywordNameFromValue(name_val);
                    keywords[kw_idx - 1] = .{ .arg = name, .value = value };
                    kw_filled += 1;
                    value_owned = false;
                }

                keywords[num_kw] = .{ .arg = null, .value = kwargs_expr };
                kw_filled += 1;
                kwargs_owned = false;

                const pos_vals = try self.stack.popN(num_pos);
                var pos_owned = true;
                errdefer if (pos_owned) self.deinitStackValues(pos_vals);

                const pos_exprs = try self.stack.valuesToExprs(pos_vals);
                pos_owned = false;
                var pos_exprs_owned = true;
                errdefer if (pos_exprs_owned) {
                    for (pos_exprs) |arg| {
                        arg.deinit(self.allocator);
                        self.allocator.destroy(arg);
                    }
                    self.allocator.free(pos_exprs);
                };

                const args = try self.allocator.alloc(*Expr, pos_exprs.len + 1);
                errdefer {
                    for (args) |arg| {
                        arg.deinit(self.allocator);
                        self.allocator.destroy(arg);
                    }
                    self.allocator.free(args);
                }
                @memcpy(args[0..pos_exprs.len], pos_exprs);
                args[pos_exprs.len] = starred_arg;
                star_owned = false;
                pos_exprs_owned = false;
                self.allocator.free(pos_exprs);

                const callable = self.stack.pop() orelse return error.StackUnderflow;
                switch (callable) {
                    .expr => |callee_expr| {
                        var cleanup_callee = true;
                        errdefer if (cleanup_callee) {
                            callee_expr.deinit(self.allocator);
                            self.allocator.destroy(callee_expr);
                        };
                        const call_expr = try ast.makeCallWithKeywords(self.allocator, callee_expr, args, keywords);
                        errdefer {
                            call_expr.deinit(self.allocator);
                            self.allocator.destroy(call_expr);
                        }
                        try self.stack.push(.{ .expr = call_expr });
                        cleanup_callee = false;
                    },
                    else => {
                        var val = callable;
                        val.deinit(self.allocator, self.stack_alloc);
                        return error.NotAnExpression;
                    },
                }
            },

            .CALL_FUNCTION_KW => {
                if (self.flow_mode) {
                    if (self.version.lt(3, 6)) {
                        const num_pos: usize = @intCast(inst.arg & 0xFF);
                        const num_kw: usize = @intCast((inst.arg >> 8) & 0xFF);
                        // kwargs dict
                        if (self.stack.pop()) |v| {
                            var val = v;
                            val.deinit(self.allocator, self.stack_alloc);
                        } else return error.StackUnderflow;
                        // keyword pairs
                        var kw_idx = num_kw * 2;
                        while (kw_idx > 0) : (kw_idx -= 1) {
                            if (self.stack.pop()) |v| {
                                var val = v;
                                val.deinit(self.allocator, self.stack_alloc);
                            } else return error.StackUnderflow;
                        }
                        // positional args
                        var pos_idx = num_pos;
                        while (pos_idx > 0) : (pos_idx -= 1) {
                            if (self.stack.pop()) |v| {
                                var val = v;
                                val.deinit(self.allocator, self.stack_alloc);
                            } else return error.StackUnderflow;
                        }
                    } else {
                        // kw names tuple
                        if (self.stack.pop()) |v| {
                            var val = v;
                            val.deinit(self.allocator, self.stack_alloc);
                        } else return error.StackUnderflow;
                        // args
                        var argc: usize = @intCast(inst.arg);
                        while (argc > 0) : (argc -= 1) {
                            if (self.stack.pop()) |v| {
                                var val = v;
                                val.deinit(self.allocator, self.stack_alloc);
                            } else return error.StackUnderflow;
                        }
                    }
                    // callable
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    } else return error.StackUnderflow;
                    try self.stack.push(.unknown);
                    return;
                }
                if (self.version.lt(3, 6)) {
                    const num_pos: usize = @intCast(inst.arg & 0xFF);
                    const num_kw: usize = @intCast((inst.arg >> 8) & 0xFF);

                    const kwargs_val = self.stack.pop() orelse return error.StackUnderflow;
                    const kwargs_expr = switch (kwargs_val) {
                        .expr => |expr| expr,
                        else => {
                            var val = kwargs_val;
                            val.deinit(self.allocator, self.stack_alloc);
                            return error.NotAnExpression;
                        },
                    };
                    var kwargs_owned = true;
                    errdefer if (kwargs_owned) {
                        kwargs_expr.deinit(self.allocator);
                        self.allocator.destroy(kwargs_expr);
                    };

                    var keywords = try self.allocator.alloc(ast.Keyword, num_kw + 1);
                    var kw_filled: usize = 0;
                    var cleanup_keywords = true;
                    errdefer if (cleanup_keywords) {
                        for (keywords[0..kw_filled]) |kw| {
                            if (kw.arg) |arg| self.allocator.free(arg);
                            kw.value.deinit(self.allocator);
                            self.allocator.destroy(kw.value);
                        }
                        self.allocator.free(keywords);
                    };

                    var kw_idx = num_kw;
                    while (kw_idx > 0) : (kw_idx -= 1) {
                        const value = try self.stack.popExpr();
                        var value_owned = true;
                        errdefer if (value_owned) {
                            value.deinit(self.allocator);
                            self.allocator.destroy(value);
                        };
                        const name_val = self.stack.pop() orelse return error.StackUnderflow;
                        const name = try self.keywordNameFromValue(name_val);
                        keywords[kw_idx - 1] = .{ .arg = name, .value = value };
                        kw_filled += 1;
                        value_owned = false;
                    }

                    keywords[num_kw] = .{ .arg = null, .value = kwargs_expr };
                    kw_filled += 1;
                    kwargs_owned = false;

                    const pos_vals = try self.stack.popN(num_pos);
                    var pos_owned = true;
                    errdefer if (pos_owned) self.deinitStackValues(pos_vals);

                    const args = try self.stack.valuesToExprs(pos_vals);
                    pos_owned = false;
                    var cleanup_args = true;
                    errdefer if (cleanup_args) {
                        for (args) |arg| {
                            arg.deinit(self.allocator);
                            self.allocator.destroy(arg);
                        }
                        self.allocator.free(args);
                    };

                    const callable = self.stack.pop() orelse return error.StackUnderflow;
                    switch (callable) {
                        .expr => |callee_expr| {
                            var cleanup_callee = true;
                            errdefer if (cleanup_callee) {
                                callee_expr.deinit(self.allocator);
                                self.allocator.destroy(callee_expr);
                            };
                            const expr = try ast.makeCallWithKeywords(self.allocator, callee_expr, args, keywords);
                            errdefer {
                                expr.deinit(self.allocator);
                                self.allocator.destroy(expr);
                            }
                            try self.stack.push(.{ .expr = expr });
                            cleanup_callee = false;
                            cleanup_args = false;
                            cleanup_keywords = false;
                        },
                        else => {
                            var val = callable;
                            val.deinit(self.allocator, self.stack_alloc);
                            return error.NotAnExpression;
                        },
                    }
                } else {
                    const names_val = self.stack.pop() orelse return error.StackUnderflow;
                    const kw_names = try self.keywordNamesFromValue(names_val);
                    var kw_names_owned = true;
                    errdefer if (kw_names_owned) {
                        for (kw_names) |name| {
                            if (name.len > 0) self.allocator.free(name);
                        }
                        self.allocator.free(kw_names);
                    };

                    const argc = inst.arg;
                    var args_vals = try self.stack.popN(argc);
                    var args_owned = true;
                    errdefer if (args_owned) self.deinitStackValues(args_vals);

                    const callable = self.stack.pop() orelse return error.StackUnderflow;
                    var callable_owned = true;
                    errdefer if (callable_owned) {
                        var val = callable;
                        val.deinit(self.allocator, self.stack_alloc);
                    };

                    switch (callable) {
                        .expr => |callee_expr| {
                            if (self.isBuildClass(callee_expr)) {
                                if (try self.tryBuildClassValueKw(callee_expr, args_vals, kw_names)) {
                                    callable_owned = false;
                                    args_owned = false;
                                    self.allocator.free(kw_names);
                                    kw_names_owned = false;
                                    return;
                                }
                            }
                        },
                        else => {},
                    }

                    if (kw_names.len > args_vals.len) return error.InvalidKeywordNames;

                    const pos_count = args_vals.len - kw_names.len;
                    var args: []*Expr = &.{};
                    if (pos_count > 0) {
                        args = try self.allocator.alloc(*Expr, pos_count);
                    }
                    var args_filled: usize = 0;
                    errdefer {
                        if (pos_count > 0) self.allocator.free(args);
                    }

                    for (args_vals[0..pos_count], 0..) |val, idx| {
                        switch (val) {
                            .expr => |expr| {
                                args[idx] = expr;
                                args_filled += 1;
                                args_vals[idx] = .unknown;
                            },
                            else => {
                                var tmp = val;
                                tmp.deinit(self.allocator, self.stack_alloc);
                                const expr = try self.makeName("__unknown__", .load);
                                args[idx] = expr;
                                args_filled += 1;
                                args_vals[idx] = .unknown;
                            },
                        }
                    }

                    var keywords: []ast.Keyword = &.{};
                    if (kw_names.len > 0) {
                        keywords = try self.allocator.alloc(ast.Keyword, kw_names.len);
                    }
                    var kw_filled: usize = 0;
                    errdefer {
                        if (kw_names.len > 0) self.allocator.free(keywords);
                    }

                    for (kw_names, 0..) |name, idx| {
                        const arg_idx = pos_count + idx;
                        const val = args_vals[arg_idx];
                        switch (val) {
                            .expr => |expr| {
                                const arg_name = try self.allocator.dupe(u8, name);
                                var arg_owned = true;
                                errdefer if (arg_owned) self.allocator.free(arg_name);
                                keywords[idx] = .{ .arg = arg_name, .value = expr };
                                arg_owned = false;
                                kw_filled += 1;
                                args_vals[arg_idx] = .unknown;
                            },
                            else => {
                                var tmp = val;
                                tmp.deinit(self.allocator, self.stack_alloc);
                                const expr = try self.makeName("__unknown__", .load);
                                const arg_name = try self.allocator.dupe(u8, name);
                                var arg_owned = true;
                                errdefer if (arg_owned) self.allocator.free(arg_name);
                                keywords[idx] = .{ .arg = arg_name, .value = expr };
                                arg_owned = false;
                                kw_filled += 1;
                                args_vals[arg_idx] = .unknown;
                            },
                        }
                    }

                    for (args_vals) |*val| val.* = .unknown;
                    self.stack.releasePop(args_vals);
                    args_owned = false;
                    for (kw_names) |name| {
                        if (name.len > 0) self.allocator.free(name);
                    }
                    self.allocator.free(kw_names);
                    kw_names_owned = false;

                    var callee_expr: *Expr = undefined;
                    var cleanup_callee = true;
                    switch (callable) {
                        .expr => |expr| {
                            callable_owned = false;
                            callee_expr = expr;
                        },
                        .unknown => {
                            callable_owned = false;
                            callee_expr = try self.makeName("__unknown__", .load);
                        },
                        else => {
                            var val = callable;
                            val.deinit(self.allocator, self.stack_alloc);
                            callable_owned = false;
                            callee_expr = try self.makeName("__unknown__", .load);
                        },
                    }
                    errdefer if (cleanup_callee) {
                        callee_expr.deinit(self.allocator);
                        self.allocator.destroy(callee_expr);
                        if (keywords.len > 0) deinitKeywordsOwned(self.allocator, keywords);
                        if (pos_count > 0) {
                            for (args) |arg| {
                                arg.deinit(self.allocator);
                                self.allocator.destroy(arg);
                            }
                            self.allocator.free(args);
                        }
                    };
                    const expr = try ast.makeCallWithKeywords(self.allocator, callee_expr, args, keywords);
                    errdefer {
                        expr.deinit(self.allocator);
                        self.allocator.destroy(expr);
                    }
                    try self.stack.push(.{ .expr = expr });
                    cleanup_callee = false;
                }
            },

            .CALL_FUNCTION_EX => {
                const has_kwargs = (inst.arg & 0x01) != 0;
                var kwargs_expr: ?*Expr = null;
                if (has_kwargs) {
                    const kw_val = self.stack.pop() orelse return error.StackUnderflow;
                    switch (kw_val) {
                        .expr => |expr| kwargs_expr = expr,
                        .unknown => {
                            kwargs_expr = try self.makeName("__unknown__", .load);
                        },
                        else => {
                            var val = kw_val;
                            val.deinit(self.allocator, self.stack_alloc);
                            if (self.flow_mode or self.lenient) {
                                kwargs_expr = try self.makeName("__unknown__", .load);
                            } else {
                                return error.NotAnExpression;
                            }
                        },
                    }
                }
                errdefer if (kwargs_expr) |expr| {
                    expr.deinit(self.allocator);
                    self.allocator.destroy(expr);
                };

                const args_val = self.stack.pop() orelse return error.StackUnderflow;
                const args_expr = switch (args_val) {
                    .expr => |expr| expr,
                    .unknown => try self.makeName("__unknown__", .load),
                    else => blk: {
                        var val = args_val;
                        val.deinit(self.allocator, self.stack_alloc);
                        if (self.flow_mode or self.lenient) {
                            break :blk try self.makeName("__unknown__", .load);
                        }
                        return error.NotAnExpression;
                    },
                };

                const callable = self.stack.pop() orelse return error.StackUnderflow;

                const is_empty_tuple = args_expr.* == .tuple and args_expr.tuple.elts.len == 0;
                const was_built_empty = is_empty_tuple and self.empty_tuple_builds.get(args_expr) != null;
                if (is_empty_tuple) _ = self.empty_tuple_builds.remove(args_expr);

                var args: []const *Expr = &.{};
                if (!(has_kwargs and was_built_empty)) {
                    const starred_arg = if (args_expr.* == .starred)
                        args_expr
                    else blk: {
                        errdefer {
                            args_expr.deinit(self.allocator);
                            self.allocator.destroy(args_expr);
                        }
                        break :blk try ast.makeStarred(self.allocator, args_expr, .load);
                    };
                    const args_buf = try self.allocator.alloc(*Expr, 1);
                    args_buf[0] = starred_arg;
                    args = args_buf;
                } else {
                    args_expr.deinit(self.allocator);
                    self.allocator.destroy(args_expr);
                }

                var keywords: []ast.Keyword = &.{};
                if (kwargs_expr) |expr| {
                    if (expr.* == .dict) {
                        if (try self.dictExprToKeywords(expr)) |kw_list| {
                            keywords = kw_list;
                            kwargs_expr = null;
                        }
                    }
                }
                if (keywords.len == 0) {
                    if (kwargs_expr) |expr| {
                        keywords = try self.allocator.alloc(ast.Keyword, 1);
                        keywords[0] = .{ .arg = null, .value = expr };
                        kwargs_expr = null;
                    }
                }

                var cleanup_args = args.len > 0;
                var cleanup_keywords = keywords.len > 0;
                errdefer {
                    if (cleanup_keywords) deinitKeywordsOwned(self.allocator, keywords);
                    if (cleanup_args) {
                        for (args) |arg| {
                            arg.deinit(self.allocator);
                            self.allocator.destroy(arg);
                        }
                        self.allocator.free(args);
                    }
                }

                const callee_expr = switch (callable) {
                    .expr => |expr| expr,
                    .unknown => try self.makeName("__unknown__", .load),
                    else => blk: {
                        var val = callable;
                        val.deinit(self.allocator, self.stack_alloc);
                        if (self.flow_mode or self.lenient) {
                            break :blk try self.makeName("__unknown__", .load);
                        }
                        return error.NotAnExpression;
                    },
                };
                var cleanup_callee = true;
                errdefer if (cleanup_callee) {
                    callee_expr.deinit(self.allocator);
                    self.allocator.destroy(callee_expr);
                };
                const call_expr = try ast.makeCallWithKeywords(self.allocator, callee_expr, args, keywords);
                errdefer {
                    call_expr.deinit(self.allocator);
                    self.allocator.destroy(call_expr);
                }
                try self.stack.push(.{ .expr = call_expr });
                cleanup_callee = false;
                cleanup_args = false;
                cleanup_keywords = false;
            },

            .RETURN_VALUE => {
                // Pop return value - typically ends simulation
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    if (self.lenient or self.flow_mode) return;
                    return error.StackUnderflow;
                }
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
                // Python 2.x/3.0-3.2: arg = number of defaults to pop
                // Python 3.3-3.10: arg = flags bitmap, qualname on TOS
                // Python 3.11+: arg = flags bitmap, qualname in code object

                var defaults: []const *Expr = &.{};
                var kw_defaults: []const ?*Expr = &.{};
                var annotations: []const signature.Annotation = &.{};

                // Python 3.3+ has qualname on TOS (PEP 3155) until 3.11
                if (self.version.gte(3, 3) and self.version.lt(3, 11)) {
                    if (self.stack.pop()) |qualname| {
                        var val = qualname;
                        val.deinit(self.allocator, self.stack_alloc);
                    } else {
                        return error.StackUnderflow;
                    }
                }

                // Python 2.x: arg is count of defaults
                // Python 3.0-3.2: arg low 8 bits = positional defaults, high 8 bits = kw-only defaults
                // Python 3.3+: arg is flags bitmap
                if (self.version.lt(3, 3)) {
                    // Pop the code object first
                    const code_val = self.stack.pop() orelse return error.StackUnderflow;

                    // Python 3.0-3.2: split 16-bit arg into positional and kw-only defaults
                    // Python 2.x: just positional defaults count
                    const num_pos_defaults: usize = if (self.version.gte(3, 0))
                        inst.arg & 0xFF
                    else
                        inst.arg;
                    const num_kw_defaults: usize = if (self.version.gte(3, 0))
                        (inst.arg >> 8) & 0xFF
                    else
                        0;

                    // Pop keyword-only defaults (pairs of name, value)
                    if (num_kw_defaults > 0) {
                        var i: usize = 0;
                        while (i < num_kw_defaults * 2) : (i += 1) {
                            if (self.stack.pop()) |val| {
                                var v = val;
                                v.deinit(self.allocator, self.stack_alloc);
                            } else {
                                return error.StackUnderflow;
                            }
                        }
                    }

                    // Pop positional defaults
                    if (num_pos_defaults > 0) {
                        const def_exprs = try self.allocator.alloc(*Expr, num_pos_defaults);
                        var i: usize = 0;
                        while (i < num_pos_defaults) : (i += 1) {
                            const idx = num_pos_defaults - 1 - i;
                            if (self.stack.pop()) |val| {
                                switch (val) {
                                    .expr => |e| def_exprs[idx] = e,
                                    else => {
                                        var v = val;
                                        v.deinit(self.allocator, self.stack_alloc);
                                        def_exprs[idx] = try self.makeName("<default>", .load);
                                    },
                                }
                            } else {
                                return error.StackUnderflow;
                            }
                        }
                        defaults = def_exprs;
                    }

                    switch (code_val) {
                        .code_obj => |code| {
                            if (compKindFromName(code.name)) |kind| {
                                try self.stack.push(.{ .comp_obj = .{ .code = code, .kind = kind } });
                                return;
                            }
                            if (std.mem.eql(u8, code.name, "<lambda>")) {
                                const expr = try buildLambdaExpr(self.allocator, code, self.version, defaults, kw_defaults);
                                try self.stack.push(.{ .expr = expr });
                                return;
                            }

                            const func = try self.allocator.create(FunctionValue);
                            func.* = .{
                                .code = code,
                                .decorators = .{},
                                .defaults = defaults,
                                .kw_defaults = &.{},
                                .annotations = &.{},
                            };
                            try self.stack.push(.{ .function_obj = func });
                        },
                        else => {
                            var v = code_val;
                            v.deinit(self.allocator, self.stack_alloc);
                            const expr = try self.makeName("<function>", .load);
                            try self.stack.push(.{ .expr = expr });
                        },
                }
                return;
                }

                // Python 3.3+: code object is on stack; for 3.3-3.10 the qualname was already popped above.
                const code_val = self.stack.pop() orelse return error.StackUnderflow;
                const code_ptr: ?*const pyc.Code = switch (code_val) {
                    .code_obj => |code| code,
                    else => null,
                };

                if ((inst.arg & 0x08) != 0) {
                    if (self.stack.pop()) |closure| {
                        var val = closure;
                        val.deinit(self.allocator, self.stack_alloc);
                    } else {
                        return error.StackUnderflow;
                    }
                }
                if ((inst.arg & 0x04) != 0) {
                    if (self.stack.pop()) |ann_val| {
                        annotations = try self.parseAnnotations(ann_val);
                    } else {
                        return error.StackUnderflow;
                    }
                }
                if ((inst.arg & 0x02) != 0) {
                    if (self.stack.pop()) |kwdefaults| {
                        kw_defaults = try self.parseKwDefaults(kwdefaults, code_ptr);
                    } else {
                        return error.StackUnderflow;
                    }
                }
                if ((inst.arg & 0x01) != 0) {
                    if (self.stack.pop()) |def_val| {
                        defaults = try self.parseDefaults(def_val);
                    } else {
                        return error.StackUnderflow;
                    }
                }

                switch (code_val) {
                    .code_obj => |code| {
                        if (compKindFromName(code.name)) |kind| {
                            try self.stack.push(.{ .comp_obj = .{ .code = code, .kind = kind } });
                            return;
                        }
                        if (std.mem.eql(u8, code.name, "<lambda>")) {
                            const expr = try buildLambdaExpr(self.allocator, code, self.version, defaults, kw_defaults);
                            try self.stack.push(.{ .expr = expr });
                            return;
                        }

                        const func = try self.allocator.create(FunctionValue);
                        func.* = .{
                            .code = code,
                            .decorators = .{},
                            .defaults = defaults,
                            .kw_defaults = kw_defaults,
                            .annotations = annotations,
                        };
                        try self.stack.push(.{ .function_obj = func });
                    },
                    else => {
                        // Try to get the function name from the code object
                        const func_name: []const u8 = switch (code_val) {
                            .expr => |e| blk: {
                                e.deinit(self.allocator);
                                self.allocator.destroy(e);
                                break :blk "<function>";
                            },
                            else => "<function>",
                        };

                        const expr = try self.makeName(func_name, .load);
                        try self.stack.push(.{ .expr = expr });
                    },
                }
            },

            .MAKE_CLOSURE => {
                // MAKE_CLOSURE - Python 2/3.0-3.3 version of MAKE_FUNCTION with closure
                // Stack: defaults... code closure -> function
                // In Python 3.3+, qualname is also on stack between code and defaults

                // Pop qualname for Python 3.3+
                if (self.version.gte(3, 3)) {
                    if (self.stack.pop()) |qualname| {
                        var val = qualname;
                        val.deinit(self.allocator, self.stack_alloc);
                    } else {
                        return error.StackUnderflow;
                    }
                }

                // Pop code object
                const code_val = self.stack.pop() orelse return error.StackUnderflow;

                // Pop closure tuple (already consumed by BUILD_TUPLE which pushed unknown)
                if (self.stack.pop()) |closure| {
                    var val = closure;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }

                // Parse defaults if arg > 0 (number of defaults)
                var defaults: []const *Expr = &.{};
                const defaults_count = inst.arg;
                if (defaults_count > 0) {
                    var default_list: std.ArrayListUnmanaged(*Expr) = .empty;
                    errdefer {
                        for (default_list.items) |expr| {
                            expr.deinit(self.allocator);
                            self.allocator.destroy(expr);
                        }
                        default_list.deinit(self.allocator);
                    }
                    var i: u32 = 0;
                    while (i < defaults_count) : (i += 1) {
                        if (self.stack.pop()) |def_val| {
                            if (def_val == .expr) {
                                default_list.append(self.allocator, def_val.expr) catch |err| {
                                    def_val.expr.deinit(self.allocator);
                                    self.allocator.destroy(def_val.expr);
                                    return err;
                                };
                            } else {
                                var val = def_val;
                                val.deinit(self.allocator, self.stack_alloc);
                            }
                        }
                    }
                    defaults = default_list.items;
                }

                switch (code_val) {
                    .code_obj => |code| {
                        if (compKindFromName(code.name)) |kind| {
                            try self.stack.push(.{ .comp_obj = .{ .code = code, .kind = kind } });
                            return;
                        }
                        if (std.mem.eql(u8, code.name, "<lambda>")) {
                            const expr = try buildLambdaExpr(self.allocator, code, self.version, defaults, &.{});
                            try self.stack.push(.{ .expr = expr });
                            return;
                        }

                        const func = try self.allocator.create(FunctionValue);
                        func.* = .{
                            .code = code,
                            .decorators = .{},
                            .defaults = defaults,
                            .kw_defaults = &.{},
                            .annotations = &.{},
                        };
                        try self.stack.push(.{ .function_obj = func });
                    },
                    else => {
                        const expr = try self.makeName("<closure>", .load);
                        try self.stack.push(.{ .expr = expr });
                    },
                }
            },

            .SET_FUNCTION_ATTRIBUTE => {
                // SET_FUNCTION_ATTRIBUTE flag - sets closure, defaults, annotations, etc.
                // Stack: value, func -> func
                // The flag in inst.arg determines which attribute to set:
                //   1: defaults
                //   2: kwdefaults
                //   4: annotations
                //   8: closure
                const func_val = self.stack.pop() orelse return error.StackUnderflow;
                const attr_val = self.stack.pop() orelse return error.StackUnderflow;

                if (func_val != .function_obj) {
                    attr_val.deinit(self.allocator, self.stack_alloc);
                    func_val.deinit(self.allocator, self.stack_alloc);
                    return error.NotAnExpression;
                }

                const flag = inst.arg;
                switch (flag) {
                    1 => { // defaults
                        if (attr_val == .expr) {
                            const expr = attr_val.expr;
                            switch (expr.*) {
                                .tuple => {
                                    func_val.function_obj.defaults = expr.tuple.elts;
                                },
                                .constant => |c| switch (c) {
                                    .tuple => |items| {
                                        func_val.function_obj.defaults = try self.constTupleExprs(items);
                                        expr.deinit(self.allocator);
                                        self.allocator.destroy(expr);
                                    },
                                    else => {
                                        attr_val.deinit(self.allocator, self.stack_alloc);
                                    },
                                },
                                else => {
                                    attr_val.deinit(self.allocator, self.stack_alloc);
                                },
                            }
                        } else {
                            attr_val.deinit(self.allocator, self.stack_alloc);
                        }
                    },
                    2 => { // kwdefaults
                        const func = func_val.function_obj;
                        func.kw_defaults = try self.parseKwDefaults(attr_val, func.code);
                    },
                    4 => { // annotations
                        const func = func_val.function_obj;
                        func.annotations = try self.parseAnnotations(attr_val);
                    },
                    8 => { // closure - ignore
                        attr_val.deinit(self.allocator, self.stack_alloc);
                    },
                    16 => { // annotate (Python 3.14+ - PEP 649 deferred annotations)
                        // attr_val is a function_obj containing the __annotate__ code
                        const func = func_val.function_obj;
                        if (attr_val == .function_obj) {
                            func.annotations = try self.parseAnnotateCode(attr_val.function_obj.code);
                        } else {
                            attr_val.deinit(self.allocator, self.stack_alloc);
                        }
                    },
                    else => {
                        attr_val.deinit(self.allocator, self.stack_alloc);
                    },
                }

                try self.stack.push(func_val);
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
                if (self.getDeref(inst.arg)) |name| {
                    const expr = try self.makeName(name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .STORE_DEREF => {
                // STORE_DEREF i - stores value to a cell
                if (self.stack.pop()) |v| {
                    const name = self.getDeref(inst.arg) orelse "__unknown__";
                    if (!try self.consumeCompUnpackName(name)) {
                        try self.addCompTargetName(name);
                    }
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
            },

            // Stack manipulation opcodes
            .DUP_TOP => {
                // DUP_TOP - duplicate top of stack
                const top = self.stack.peek() orelse {
                    if (self.lenient) {
                        try self.stack.push(.unknown);
                        return;
                    }
                    return error.StackUnderflow;
                };
                try self.stack.push(try self.cloneStackValue(top));
            },

            .DUP_TOP_TWO => {
                var len = self.stack.items.items.len;
                if (len < 2) {
                    if (!self.lenient) return error.StackUnderflow;
                    while (self.stack.items.items.len < 2) {
                        try self.stack.push(.unknown);
                    }
                    len = self.stack.items.items.len;
                }
                try self.stack.items.ensureUnusedCapacity(self.allocator, 2);
                const second = self.stack.items.items[len - 2];
                const top = self.stack.items.items[len - 1];
                try self.stack.push(try self.cloneStackValue(second));
                try self.stack.push(try self.cloneStackValue(top));
            },

            .DUP_TOPX => {
                const count: usize = @intCast(inst.arg);
                if (count == 0) return error.InvalidDupArg;
                if (count > self.stack.items.items.len) {
                    if (!self.lenient) return error.StackUnderflow;
                    while (self.stack.items.items.len < count) {
                        try self.stack.push(.unknown);
                    }
                }
                try self.stack.items.ensureUnusedCapacity(self.allocator, count);

                const start = self.stack.items.items.len - count;
                const items = self.stack.items.items;

                var clones = try self.stack_alloc.alloc(StackValue, count);
                defer self.stack_alloc.free(clones);
                var cloned_count: usize = 0;
                errdefer {
                    for (clones[0..cloned_count]) |*val| val.deinit(self.allocator, self.stack_alloc);
                }

                var i: usize = 0;
                while (i < count) : (i += 1) {
                    clones[i] = try self.cloneStackValue(items[start + i]);
                    cloned_count += 1;
                }

                for (clones) |val| {
                    try self.stack.push(val);
                }
            },

            .ROT_TWO => {
                if (self.stack.items.items.len < 2) {
                    if (!self.lenient) return error.StackUnderflow;
                    while (self.stack.items.items.len < 2) {
                        try self.stack.push(.unknown);
                    }
                }
                const len = self.stack.items.items.len;
                const tmp = self.stack.items.items[len - 1];
                self.stack.items.items[len - 1] = self.stack.items.items[len - 2];
                self.stack.items.items[len - 2] = tmp;
            },

            .ROT_THREE => {
                if (self.stack.items.items.len < 3) {
                    if (!self.lenient) return error.StackUnderflow;
                    while (self.stack.items.items.len < 3) {
                        try self.stack.push(.unknown);
                    }
                }
                const len = self.stack.items.items.len;
                const top = self.stack.items.items[len - 1];
                const second = self.stack.items.items[len - 2];
                const third = self.stack.items.items[len - 3];
                self.stack.items.items[len - 1] = second;
                self.stack.items.items[len - 2] = third;
                self.stack.items.items[len - 3] = top;
            },

            .ROT_FOUR => {
                if (self.stack.items.items.len < 4) {
                    if (!self.lenient) return error.StackUnderflow;
                    while (self.stack.items.items.len < 4) {
                        try self.stack.push(.unknown);
                    }
                }
                const len = self.stack.items.items.len;
                const top = self.stack.items.items[len - 1];
                const second = self.stack.items.items[len - 2];
                const third = self.stack.items.items[len - 3];
                const fourth = self.stack.items.items[len - 4];
                self.stack.items.items[len - 1] = second;
                self.stack.items.items[len - 2] = third;
                self.stack.items.items[len - 3] = fourth;
                self.stack.items.items[len - 4] = top;
            },

            .ROT_N => {
                const count: usize = @intCast(inst.arg);
                if (count < 2) return error.InvalidSwapArg;
                const len = self.stack.items.items.len;
                if (count > len) {
                    if (!self.lenient) return error.StackUnderflow;
                    while (self.stack.items.items.len < count) {
                        try self.stack.push(.unknown);
                    }
                }
                const start = len - count;
                const top = self.stack.items.items[len - 1];
                var idx = len - 1;
                while (idx > start) : (idx -= 1) {
                    self.stack.items.items[idx] = self.stack.items.items[idx - 1];
                }
                self.stack.items.items[start] = top;
            },

            .SWAP => {
                // SWAP i - swap TOS with stack item at position i
                if (inst.arg < 2) return error.InvalidSwapArg;
                const pos = inst.arg - 1;
                if (pos >= self.stack.items.items.len) {
                    if (self.stack.allow_underflow or self.lenient) return;
                    return error.StackUnderflow;
                }
                const top_idx = self.stack.items.items.len - 1;
                const swap_idx = self.stack.items.items.len - 1 - pos;
                const tmp = self.stack.items.items[top_idx];
                self.stack.items.items[top_idx] = self.stack.items.items[swap_idx];
                self.stack.items.items[swap_idx] = tmp;
            },

            .COPY => {
                // COPY i - copy stack item at position i to TOS
                const pos = inst.arg;
                if (pos < 1 or pos > self.stack.items.items.len) {
                    if (self.lenient) {
                        try self.stack.push(.unknown);
                        return;
                    }
                    return error.StackUnderflow;
                }
                const copy_idx = self.stack.items.items.len - pos;
                const val = self.stack.items.items[copy_idx];
                try self.stack.push(try self.cloneStackValue(val));
            },

            // Unary operators
            .UNARY_POSITIVE => {
                const operand = try self.stack.popExpr();
                errdefer {
                    operand.deinit(self.allocator);
                    self.allocator.destroy(operand);
                }
                const expr = try ast.makeUnaryOp(self.allocator, .uadd, operand);
                try self.stack.push(.{ .expr = expr });
            },

            .UNARY_NEGATIVE => {
                const operand = try self.stack.popExpr();
                errdefer {
                    operand.deinit(self.allocator);
                    self.allocator.destroy(operand);
                }
                const expr = try ast.makeUnaryOp(self.allocator, .usub, operand);
                try self.stack.push(.{ .expr = expr });
            },

            .UNARY_NOT => {
                const operand = try self.stack.popExpr();
                errdefer {
                    operand.deinit(self.allocator);
                    self.allocator.destroy(operand);
                }
                const expr = try ast.makeUnaryOp(self.allocator, .not_, operand);
                try self.stack.push(.{ .expr = expr });
            },

            .UNARY_INVERT => {
                const operand = try self.stack.popExpr();
                errdefer {
                    operand.deinit(self.allocator);
                    self.allocator.destroy(operand);
                }
                const expr = try ast.makeUnaryOp(self.allocator, .invert, operand);
                try self.stack.push(.{ .expr = expr });
            },

            .UNARY_CONVERT => {
                const operand = try self.stack.popExpr();
                errdefer {
                    operand.deinit(self.allocator);
                    self.allocator.destroy(operand);
                }
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .repr_expr = .{ .value = operand } };
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
                if (self.lenient) {
                    // Even in lenient simulation we want iterator cleanup (`POP_TOP`) to be
                    // discarded, not emitted as a stray expression statement.
                    if (self.stack.items.items.len > 0 and self.stack.items.items[self.stack.items.items.len - 1] == .expr) {
                        self.stack.items.items[self.stack.items.items.len - 1] = .unknown;
                    }
                    try self.stack.push(.unknown);
                    return;
                }
                if (self.comp_builder) |builder| {
                    const top = self.stack.peek() orelse return error.StackUnderflow;
                    switch (top) {
                        .expr => |iter_expr| {
                            const top_idx = self.stack.items.items.len - 1;
                            self.stack.items.items[top_idx] = .unknown;
                            try self.addCompGenerator(builder, iter_expr);
                        },
                        else => return error.NotAnExpression,
                    }
                } else if (self.findCompContainer()) |container| {
                    const builder = try self.ensureCompBuilderAt(container.idx, container.kind);
                    const top = self.stack.peek() orelse return error.StackUnderflow;
                    switch (top) {
                        .expr => |iter_expr| {
                            const top_idx = self.stack.items.items.len - 1;
                            self.stack.items.items[top_idx] = .unknown;
                            try self.addCompGenerator(builder, iter_expr);
                        },
                        else => return error.NotAnExpression,
                    }
                } else {
                    // In a normal `for` loop the iterator value lives on the eval stack for the
                    // duration of the loop and is popped implicitly by `POP_TOP` when the loop
                    // exits (including `break`). Treat it as unknown so we don't emit a spurious
                    // expression statement for iterator cleanup.
                    if (self.stack.items.items.len > 0 and self.stack.items.items[self.stack.items.items.len - 1] == .expr) {
                        self.stack.items.items[self.stack.items.items.len - 1] = .unknown;
                    }
                }

                // Push the iteration value placeholder
                try self.stack.push(.unknown);
            },
            .FOR_LOOP => {
                // FOR_LOOP (Python 1.x-2.2): Stack [seq, idx] -> [seq, idx+1, element]
                // Pops index, increments, pushes back index+1 and next element
                // On exhaustion: pops both, jumps
                _ = self.stack.pop() orelse return error.StackUnderflow; // pop index
                // Sequence remains on stack
                try self.stack.push(.unknown); // push index+1
                try self.stack.push(.unknown); // push element
            },

            // Import opcodes
            .IMPORT_NAME => {
                // IMPORT_NAME namei - imports module names[namei]
                // Stack (Python 2.5+): level, fromlist -> module
                // Stack (Python 2.0-2.4): fromlist -> module
                // Stack (Python < 2.0): -> module (no stack arguments)
                var fromlist_val: ?StackValue = null;
                var level: u32 = 0;
                if (self.version.gte(2, 0)) {
                    fromlist_val = self.stack.pop() orelse return error.StackUnderflow;
                    if (self.version.gte(2, 5)) {
                        const level_val = self.stack.pop() orelse return error.StackUnderflow;
                        defer if (!self.flow_mode) level_val.deinit(self.allocator, self.stack_alloc);
                        if (level_val == .expr and level_val.expr.* == .constant) {
                            switch (level_val.expr.constant) {
                                .int => |v| {
                                    if (v >= 0) level = @intCast(v);
                                },
                                else => {},
                            }
                        }
                    }
                }
                defer if (fromlist_val) |fv| if (!self.flow_mode) fv.deinit(self.allocator, self.stack_alloc);

                // Extract fromlist tuple if available
                var fromlist: []const []const u8 = &.{};
                if (fromlist_val) |fv| {
                    if (fv == .expr) {
                        switch (fv.expr.*) {
                            .tuple => |tup| {
                                const tuple_elts = tup.elts;
                                var names: std.ArrayListUnmanaged([]const u8) = .{};
                                for (tuple_elts) |elt| {
                                    if (elt.* == .constant and elt.constant == .string) {
                                        try names.append(self.allocator, elt.constant.string);
                                    }
                                }
                                fromlist = try names.toOwnedSlice(self.allocator);
                            },
                            .constant => |c| switch (c) {
                                .tuple => |items| {
                                    var names: std.ArrayListUnmanaged([]const u8) = .{};
                                    for (items) |item| {
                                        if (item == .string) {
                                            try names.append(self.allocator, item.string);
                                        }
                                    }
                                    fromlist = try names.toOwnedSlice(self.allocator);
                                },
                                else => {},
                            },
                            else => {},
                        }
                    }
                }

                if (self.getName(inst.arg)) |module_name| {
                    try self.stack.push(.{ .import_module = .{
                        .module = module_name,
                        .fromlist = fromlist,
                        .level = level,
                    } });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .IMPORT_FROM => {
                // IMPORT_FROM namei - load attribute names[namei] from module on TOS
                // Stack: module -> module, attr
                // Module stays on stack, attr is pushed
                const top = self.stack.items.items[self.stack.items.items.len - 1];
                if (top == .import_module) {
                    if (self.getName(inst.arg)) |attr_name| {
                        const imp = top.import_module;
                        if (imp.fromlist.len == 0) {
                            if (std.mem.lastIndexOfScalar(u8, imp.module, '.')) |dot| {
                                if (std.mem.eql(u8, imp.module[dot + 1 ..], attr_name)) {
                                    try self.stack.push(.{ .import_module = .{
                                        .module = imp.module,
                                        .fromlist = &.{},
                                        .level = imp.level,
                                    } });
                                    return;
                                }
                            }
                        }
                        var new_fromlist: std.ArrayListUnmanaged([]const u8) = .{};
                        try new_fromlist.appendSlice(self.allocator, imp.fromlist);
                        try new_fromlist.append(self.allocator, attr_name);
                        const top_idx = self.stack.items.items.len - 1;
                        self.stack.items.items[top_idx] = .{ .import_module = .{
                            .module = imp.module,
                            .fromlist = try new_fromlist.toOwnedSlice(self.allocator),
                            .level = imp.level,
                        } };
                        try self.stack.push(.{ .import_module = .{
                            .module = imp.module,
                            .fromlist = &.{attr_name},
                            .level = imp.level,
                        } });
                    } else {
                        try self.stack.push(.unknown);
                    }
                } else {
                    try self.stack.push(.unknown);
                }
            },
            .IMPORT_STAR => {
                // IMPORT_STAR - consumes the module from stack, pushes nothing
                if (self.stack.pop()) |v| {
                    if (!self.flow_mode) {
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    }
                } else {
                    return error.StackUnderflow;
                }
            },

            // Attribute access
            .LOAD_ATTR => {
                // LOAD_ATTR namei - replace TOS with TOS.names[namei]
                // 3.12+: low bit indicates method load, namei>>1 is the name index
                // Pre-3.12: namei is used directly
                const obj_val = self.stack.pop() orelse return error.StackUnderflow;
                const push_null = self.version.gte(3, 12) and (inst.arg & 1) == 1;
                switch (obj_val) {
                    .expr => |obj| {
                        errdefer {
                            obj.deinit(self.allocator);
                            self.allocator.destroy(obj);
                        }
                        const name_idx = if (self.version.gte(3, 12)) inst.arg >> 1 else inst.arg;
                        if (self.getName(name_idx)) |attr_name| {
                            const attr = try self.makeAttribute(obj, attr_name, .load);
                            // In 3.12+: push NULL/self BEFORE callable for method call preparation
                            // Stack order: [NULL/self, callable, args...] from bottom to top
                            if (push_null) try self.stack.push(.null_marker);
                            try self.stack.push(.{ .expr = attr });
                        } else {
                            obj.deinit(self.allocator);
                            self.allocator.destroy(obj);
                            if (push_null) try self.stack.push(.null_marker);
                            try self.stack.push(.unknown);
                        }
                    },
                    .import_module => |imp| {
                        // IMPORT_NAME returns the top-level package; LOAD_ATTR extracts the submodule.
                        // Keep the import module so STORE_NAME can emit the import statement.
                        try self.stack.push(.{ .import_module = imp });
                    },
                    else => {
                        var val = obj_val;
                        val.deinit(self.allocator, self.stack_alloc);
                        return error.NotAnExpression;
                    },
                }
            },

            .LOAD_METHOD => {
                // LOAD_METHOD namei - prepare method call with optional self slot
                // All versions: Stack order [NULL/self, method] with method on top
                // For CALL, stack is [NULL/self, callable, args...]
                // Note: LOAD_METHOD uses raw namei, unlike LOAD_ATTR which uses arg>>1 in 3.11+
                const obj = try self.stack.popExpr();
                errdefer {
                    obj.deinit(self.allocator);
                    self.allocator.destroy(obj);
                }
                const name_idx = inst.arg;
                if (self.getName(name_idx)) |attr_name| {
                    const attr = try self.makeAttribute(obj, attr_name, .load);
                    // NULL on bottom, method on top
                    try self.stack.push(.null_marker);
                    try self.stack.push(.{ .expr = attr });
                } else {
                    obj.deinit(self.allocator);
                    self.allocator.destroy(obj);
                    try self.stack.push(.null_marker);
                    try self.stack.push(.unknown);
                }
            },

            .LOAD_SPECIAL => {
                // LOAD_SPECIAL namei - load special method from TOS (3.14+)
                // If method: pushes [method, self] with self on top
                // If not method: pushes [attr, NULL] with NULL on top
                // Special method names: 0=__enter__, 1=__exit__, etc.
                const obj = try self.stack.popExpr();
                const special_names = [_][]const u8{ "__enter__", "__exit__", "__aenter__", "__aexit__" };
                const attr_name = if (inst.arg < special_names.len) special_names[inst.arg] else "__special__";
                // Clone obj first since makeAttribute consumes it
                const obj_copy = try ast.cloneExpr(self.allocator, obj);
                errdefer {
                    obj_copy.deinit(self.allocator);
                    self.allocator.destroy(obj_copy);
                }
                const attr = try self.makeAttribute(obj, attr_name, .load);
                // For context managers, these are methods - push [method, self]
                try self.stack.push(.{ .expr = attr });
                try self.stack.push(.{ .expr = obj_copy });
            },

            .STORE_ATTR => {
                // STORE_ATTR namei - TOS.names[namei] = TOS1
                // Stack: obj, value -> (empty)
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
            },

            // Subscript operations
            .BINARY_SUBSCR => {
                // BINARY_SUBSCR - TOS = TOS1[TOS]
                const index = try self.stack.popExpr();
                errdefer {
                    index.deinit(self.allocator);
                    self.allocator.destroy(index);
                }
                const container = try self.stack.popExpr();
                errdefer {
                    container.deinit(self.allocator);
                    self.allocator.destroy(container);
                }
                const expr = try ast.makeSubscript(self.allocator, container, index, .load);
                try self.stack.push(.{ .expr = expr });
            },

            .SLICE_0, .SLICE_1, .SLICE_2, .SLICE_3 => {
                var lower: ?*Expr = null;
                var upper: ?*Expr = null;
                const container = switch (inst.opcode) {
                    .SLICE_0 => try self.stack.popExpr(),
                    .SLICE_1 => blk: {
                        const start = try self.stack.popExpr();
                        lower = start;
                        break :blk try self.stack.popExpr();
                    },
                    .SLICE_2 => blk: {
                        const stop = try self.stack.popExpr();
                        upper = stop;
                        break :blk try self.stack.popExpr();
                    },
                    .SLICE_3 => blk: {
                        const stop = try self.stack.popExpr();
                        upper = stop;
                        const start = try self.stack.popExpr();
                        lower = start;
                        break :blk try self.stack.popExpr();
                    },
                    else => unreachable,
                };

                const lower_val = if (lower) |l| (if (isNoneExpr(l)) null else l) else null;
                const upper_val = if (upper) |u| (if (isNoneExpr(u)) null else u) else null;

                const slice = try self.allocator.create(Expr);
                slice.* = .{ .slice = .{ .lower = lower_val, .upper = upper_val, .step = null } };
                const expr = try ast.makeSubscript(self.allocator, container, slice, .load);
                try self.stack.push(.{ .expr = expr });
            },

            .BINARY_SLICE => {
                // BINARY_SLICE (Python 3.12+) - TOS = TOS2[TOS1:TOS]
                const stop = try self.stack.popExpr();
                const start = try self.stack.popExpr();
                const container = try self.stack.popExpr();

                // Convert None to null for slice bounds
                const lower: ?*Expr = if (isNoneExpr(start)) null else start;
                const upper: ?*Expr = if (isNoneExpr(stop)) null else stop;

                const slice = try self.allocator.create(Expr);
                slice.* = .{ .slice = .{ .lower = lower, .upper = upper, .step = null } };

                const expr = try ast.makeSubscript(self.allocator, container, slice, .load);
                try self.stack.push(.{ .expr = expr });
            },

            .STORE_SLICE => {
                // STORE_SLICE (Python 3.12+) - TOS3[TOS2:TOS1] = TOS
                _ = self.stack.pop();
                _ = self.stack.pop();
                _ = self.stack.pop();
                _ = self.stack.pop();
            },

            .STORE_SLICE_0, .STORE_SLICE_1, .STORE_SLICE_2, .STORE_SLICE_3 => {
                // Legacy STORE_SLICE+* (Python 2.x)
                _ = self.stack.pop(); // value
                switch (inst.opcode) {
                    .STORE_SLICE_0 => {
                        _ = self.stack.pop(); // container
                    },
                    .STORE_SLICE_1 => {
                        _ = self.stack.pop(); // start
                        _ = self.stack.pop(); // container
                    },
                    .STORE_SLICE_2 => {
                        _ = self.stack.pop(); // stop
                        _ = self.stack.pop(); // container
                    },
                    .STORE_SLICE_3 => {
                        _ = self.stack.pop(); // stop
                        _ = self.stack.pop(); // start
                        _ = self.stack.pop(); // container
                    },
                    else => {},
                }
            },

            .STORE_SUBSCR => {
                // STORE_SUBSCR - TOS1[TOS] = TOS2
                // Stack: key, container, value -> (empty)
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
            },

            // Dict operations
            .BUILD_MAP => {
                // Python 3.6+: BUILD_MAP count - create dict from count key/value pairs on stack
                // Python 3.0-3.5: BUILD_MAP capacity - create empty dict, pairs added via STORE_MAP
                const count = inst.arg;
                const expr = try self.allocator.create(Expr);
                errdefer self.allocator.destroy(expr);

                if (count == 0 or self.version.lt(3, 6)) {
                    // Pre-3.6 or empty dict: create empty dict (pairs added via STORE_MAP)
                    expr.* = .{ .dict = .{ .keys = &.{}, .values = &.{} } };
                } else {
                    const keys = try self.allocator.alloc(?*Expr, count);
                    const values = try self.allocator.alloc(*Expr, count);
                    var filled: usize = 0;
                    errdefer {
                        var j: usize = 0;
                        while (j < filled) : (j += 1) {
                            const idx = count - 1 - j;
                            if (keys[idx]) |k| {
                                k.deinit(self.allocator);
                                self.allocator.destroy(k);
                            }
                            values[idx].deinit(self.allocator);
                            self.allocator.destroy(values[idx]);
                        }
                        self.allocator.free(keys);
                        self.allocator.free(values);
                    }

                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const val = try self.stack.popExpr();
                        const key = self.stack.popExpr() catch |err| {
                            val.deinit(self.allocator);
                            self.allocator.destroy(val);
                            return err;
                        };
                        keys[count - 1 - i] = key;
                        values[count - 1 - i] = val;
                        filled += 1;
                    }
                    expr.* = .{ .dict = .{ .keys = keys, .values = values } };
                }
                try self.stack.push(.{ .expr = expr });
            },

            .BUILD_MAP_UNPACK, .BUILD_MAP_UNPACK_WITH_CALL => {
                try self.buildDictUnpack(inst.arg);
            },

            .STORE_MAP => {
                // STORE_MAP - Python 2.x and 3.0-3.5
                // Stack: dict, value, key -> dict (with key:value added)
                // TOS is key, TOS1 is value
                const key = try self.stack.popExpr();
                errdefer {
                    key.deinit(self.allocator);
                    self.allocator.destroy(key);
                }
                const value = try self.stack.popExpr();
                errdefer {
                    value.deinit(self.allocator);
                    self.allocator.destroy(value);
                }
                const dict_val = self.stack.pop() orelse return error.StackUnderflow;

                if (dict_val == .expr and dict_val.expr.* == .dict) {
                    const dict = &dict_val.expr.dict;
                    // Append key/value to existing dict
                    const old_len = dict.keys.len;
                    const new_keys = try self.allocator.alloc(?*Expr, old_len + 1);
                    const new_vals = try self.allocator.alloc(*Expr, old_len + 1);
                    @memcpy(new_keys[0..old_len], dict.keys);
                    @memcpy(new_vals[0..old_len], dict.values);
                    new_keys[old_len] = key;
                    new_vals[old_len] = value;
                    if (old_len > 0) {
                        self.allocator.free(dict.keys);
                        self.allocator.free(dict.values);
                    }
                    dict.keys = new_keys;
                    dict.values = new_vals;
                    try self.stack.push(dict_val);
                } else {
                    // Not a dict on stack, just discard
                    dict_val.deinit(self.allocator, self.stack_alloc);
                    key.deinit(self.allocator);
                    self.allocator.destroy(key);
                    value.deinit(self.allocator);
                    self.allocator.destroy(value);
                }
            },

            .BUILD_CONST_KEY_MAP => {
                // BUILD_CONST_KEY_MAP count - create dict from tuple of keys and count values
                // Stack: keys_tuple, val1, val2, ..., valN -> dict
                const count = inst.arg;

                // Pop values first (TOS down to TOS-count+1)
                const keys_val = self.stack.pop() orelse return error.StackUnderflow;
                defer keys_val.deinit(self.allocator, self.stack_alloc);

                // Pop values in reverse order
                const values = try self.allocator.alloc(*Expr, count);
                errdefer self.allocator.free(values);

                var i: usize = 0;
                while (i < count) : (i += 1) {
                    values[count - 1 - i] = try self.stack.popExpr();
                }
                errdefer {
                    for (values) |v| {
                        v.deinit(self.allocator);
                        self.allocator.destroy(v);
                    }
                }

                // Extract keys from tuple expr
                const keys = try self.allocator.alloc(?*Expr, count);
                errdefer self.allocator.free(keys);

                if (keys_val == .expr) {
                    switch (keys_val.expr.*) {
                        .tuple => |tup| {
                            const key_exprs = tup.elts;
                            if (key_exprs.len != count) return error.InvalidConstKeyMap;

                            for (key_exprs, 0..) |key, j| {
                                keys[j] = try ast.cloneExpr(self.allocator, key);
                            }
                        },
                        .constant => |c| {
                            // Constant wraps a tuple - extract it
                            switch (c) {
                                .tuple => |items| {
                                    if (items.len != count) return error.InvalidConstKeyMap;
                                    for (items, 0..) |item, j| {
                                        const key_expr = try ast.makeConstant(self.allocator, item);
                                        keys[j] = key_expr;
                                    }
                                },
                                else => {
                                    // Fall back to unknown keys
                                    for (keys) |*k| k.* = null;
                                },
                            }
                        },
                        else => {
                            // Fall back to unknown keys
                            for (keys) |*k| k.* = null;
                        },
                    }
                } else {
                    // Fall back to unknown keys
                    for (keys) |*k| k.* = null;
                }

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .dict = .{ .keys = keys, .values = values } };
                try self.stack.push(.{ .expr = expr });
            },

            // Slice operations
            .BUILD_SLICE => {
                // BUILD_SLICE argc - build slice from argc elements
                // argc=2: TOS1:TOS, argc=3: TOS2:TOS1:TOS
                // None values become null (omitted in output like [::-1])
                const argc = inst.arg;
                var step: ?*Expr = null;
                if (argc == 3) {
                    const step_expr = try self.stack.popExpr();
                    if (step_expr.* == .constant and step_expr.constant == .none) {
                        step_expr.deinit(self.allocator);
                        self.allocator.destroy(step_expr);
                    } else {
                        step = step_expr;
                    }
                }
                errdefer if (step) |s| {
                    s.deinit(self.allocator);
                    self.allocator.destroy(s);
                };
                const stop_expr = try self.stack.popExpr();
                var stop: ?*Expr = null;
                if (stop_expr.* == .constant and stop_expr.constant == .none) {
                    stop_expr.deinit(self.allocator);
                    self.allocator.destroy(stop_expr);
                } else {
                    stop = stop_expr;
                }
                errdefer if (stop) |s| {
                    s.deinit(self.allocator);
                    self.allocator.destroy(s);
                };
                const start_expr = try self.stack.popExpr();
                var start: ?*Expr = null;
                if (start_expr.* == .constant and start_expr.constant == .none) {
                    start_expr.deinit(self.allocator);
                    self.allocator.destroy(start_expr);
                } else {
                    start = start_expr;
                }
                errdefer if (start) |s| {
                    s.deinit(self.allocator);
                    self.allocator.destroy(s);
                };

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .slice = .{
                    .lower = start,
                    .upper = stop,
                    .step = step,
                } };
                try self.stack.push(.{ .expr = expr });
            },

            // Class-related opcodes
            .BUILD_CLASS => {
                var methods_val = self.stack.pop() orelse return error.StackUnderflow;
                const bases_val = self.stack.pop() orelse {
                    methods_val.deinit(self.allocator, self.stack_alloc);
                    return error.StackUnderflow;
                };
                const name_val = self.stack.pop() orelse {
                    bases_val.deinit(self.allocator, self.stack_alloc);
                    methods_val.deinit(self.allocator, self.stack_alloc);
                    return error.StackUnderflow;
                };

                const class_name = self.takeClassName(name_val) catch |err| {
                    bases_val.deinit(self.allocator, self.stack_alloc);
                    methods_val.deinit(self.allocator, self.stack_alloc);
                    return err;
                };
                const bases = self.takeClassBases(bases_val) catch |err| {
                    self.allocator.free(class_name);
                    methods_val.deinit(self.allocator, self.stack_alloc);
                    return err;
                };

                if (methods_val == .class_obj) {
                    const cls = methods_val.class_obj;
                    if (cls.name.len > 0) self.allocator.free(cls.name);
                    if (cls.bases.len > 0) {
                        deinitExprSlice(self.allocator, cls.bases);
                        cls.bases = &.{};
                    }
                    cls.name = class_name;
                    cls.bases = bases;
                    try self.stack.push(.{ .class_obj = cls });
                } else {
                    self.allocator.free(class_name);
                    deinitExprSlice(self.allocator, bases);
                    methods_val.deinit(self.allocator, self.stack_alloc);
                    return error.NotAnExpression;
                }
            },
            .LOAD_BUILD_CLASS => {
                // LOAD_BUILD_CLASS - push __build_class__ builtin onto stack
                // Used to construct classes: __build_class__(func, name, *bases, **keywords)
                const expr = try self.makeName("__build_class__", .load);
                try self.stack.push(.{ .expr = expr });
            },

            .LOAD_LOCALS => {
                // LOAD_LOCALS - Python 2.x: push locals() dict onto stack
                // Used at end of class body to return the class namespace
                const func_expr = try self.makeName("locals", .load);
                const expr = try ast.makeCall(self.allocator, func_expr, &.{});
                try self.stack.push(.{ .expr = expr });
            },

            .STORE_LOCALS => {
                // STORE_LOCALS - Python 3.0-3.3: store TOS to locals (used in class bodies)
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
            },

            .LOAD_CLASSDEREF => {
                // LOAD_CLASSDEREF i - load value from cell or free variable for class scoping
                if (self.getDeref(inst.arg)) |name| {
                    const expr = try self.makeName(name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            // Exception handling opcodes
            .PUSH_EXC_INFO => {
                // PUSH_EXC_INFO - pushes exception info onto stack
                // Used when entering except handler, pushes (exc, tb)
                try self.stack.push(.exc_marker);
            },

            .CHECK_EXC_MATCH => {
                // CHECK_EXC_MATCH - checks if TOS matches TOS1 exception type
                // Pops the exception type, leaves bool result on stack
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
                try self.stack.push(.unknown);
            },

            .CHECK_EG_MATCH => {
                // CHECK_EG_MATCH - except* matching (PEP 654)
                // TOS=exception type, TOS1=exception group
                // Pops 2, pushes (non-matching group, matching group)
                _ = self.stack.pop() orelse return error.StackUnderflow;
                _ = self.stack.pop() orelse return error.StackUnderflow;
                try self.stack.push(.unknown); // non-matching group
                try self.stack.push(.unknown); // matching group
            },

            .JUMP_IF_NOT_EXC_MATCH => {
                // JUMP_IF_NOT_EXC_MATCH - pop two exception values
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
            },

            .RERAISE => {
                // RERAISE depth - re-raise the exception
                // Pops nothing new, exception info already on stack
            },

            .BEFORE_ASYNC_WITH => {
                // BEFORE_ASYNC_WITH - pop async context manager, push (__aexit__, __aenter__ awaitable).
                // The subsequent GET_AWAITABLE/YIELD_FROM will await the __aenter__ result.
                const ctx = try self.stack.popExpr();
                ctx.deinit(self.allocator);
                self.allocator.destroy(ctx);

                // Push exit func placeholder and __aenter__ awaitable placeholder.
                const exit_expr = try self.makeName("__with_exit__", .load);
                try self.stack.push(.{ .expr = exit_expr });
                const enter_expr = try self.makeName("__with_enter__", .load);
                try self.stack.push(.{ .expr = enter_expr });
            },

            .SETUP_WITH => {
                // SETUP_WITH - pop context manager, push (__exit__, __enter__ result)
                const ctx = try self.stack.popExpr();
                ctx.deinit(self.allocator);
                self.allocator.destroy(ctx);
                // Push exit func placeholder and __enter__ result placeholder
                const exit_expr = try self.makeName("__with_exit__", .load);
                try self.stack.push(.{ .expr = exit_expr });
                try self.stack.push(.unknown);
            },

            .SETUP_ASYNC_WITH => {
                // SETUP_ASYNC_WITH doesn't modify the value stack on the normal path (3.5-3.10).
                // BEFORE_ASYNC_WITH already pushed (__aexit__, __aenter__ awaitable) and the await
                // sequence produced the __aenter__ result on stack.
            },

            .WITH_EXCEPT_START => {
                // WITH_EXCEPT_START - call __exit__ with exception details
                // In 3.0-3.10 this is effectively net +1 (inputs stay for cleanup).
                // In 3.11+ an exception-info placeholder is consumed, keeping net 0.
                if (self.version.gte(3, 11)) {
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    } else if (!(self.lenient or self.flow_mode)) {
                        return error.StackUnderflow;
                    }
                }
                try self.stack.push(.unknown);
            },

            .WITH_CLEANUP => {
                // WITH_CLEANUP (Python 2.x/3.3 legacy) - cleanup for with statement
                // 2.x stack effect: pop 4, push 3 (exc info placeholders)
                // 3.3 legacy: pop 1, push 0
                if (self.version.major <= 2) {
                    var i: usize = 0;
                    while (i < 4) : (i += 1) {
                        if (self.stack.pop()) |v| {
                            var val = v;
                            val.deinit(self.allocator, self.stack_alloc);
                        } else if (!(self.lenient or self.flow_mode)) {
                            return error.StackUnderflow;
                        } else {
                            break;
                        }
                    }
                    i = 0;
                    while (i < 3) : (i += 1) {
                        try self.stack.push(.exc_marker);
                    }
                } else {
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    } else if (!(self.lenient or self.flow_mode)) {
                        return error.StackUnderflow;
                    }
                }
            },

            .END_FINALLY => {
                // END_FINALLY pops a why code plus optional values:
                // 1: None (normal), 2: return/continue value, 4: exc_type, exc, tb, why.
                const len = self.stack.items.items.len;
                var drop: usize = 0;
                if (self.version.major <= 2) {
                    drop = if (len >= 3) 3 else len;
                } else if (self.version.gte(3, 7) and self.version.lt(3, 9)) {
                    drop = if (len >= 6) 6 else len;
                } else if (len >= 3) {
                    const a = self.stack.items.items[len - 1];
                    const b = self.stack.items.items[len - 2];
                    const c = self.stack.items.items[len - 3];
                    if (isExcPh(a) and isExcPh(b) and isExcPh(c)) {
                        drop = 3;
                    } else if (len >= 2) {
                        drop = 2;
                    } else {
                        drop = 1;
                    }
                } else if (len >= 2) {
                    drop = 2;
                } else if (len >= 1) {
                    drop = 1;
                }

                var i: usize = 0;
                while (i < drop) : (i += 1) {
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    } else if (!(self.lenient or self.flow_mode)) {
                        return error.StackUnderflow;
                    } else {
                        break;
                    }
                }
            },

            .SETUP_FINALLY,
            .BEGIN_FINALLY,
            .CALL_FINALLY,
            .POP_FINALLY,
            .WITH_CLEANUP_START,
            .WITH_CLEANUP_FINISH,
            => {
                // These are control flow markers, no stack effect
            },

            .POP_EXCEPT => {
                const drop: usize = if (self.version.gte(3, 11))
                    1
                else if (self.version.gte(3, 7))
                    3
                else
                    0;
                if (drop > 0) {
                    var i: usize = 0;
                    while (i < drop) : (i += 1) {
                        if (self.stack.pop()) |v| {
                            var val = v;
                            val.deinit(self.allocator, self.stack_alloc);
                        } else if (!(self.lenient or self.flow_mode)) {
                            return error.StackUnderflow;
                        } else {
                            break;
                        }
                    }
                }
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

            .DELETE_SUBSCR => {
                // DELETE_SUBSCR - delete container[key]
                const key = self.stack.pop() orelse return error.StackUnderflow;
                const container = self.stack.pop() orelse {
                    var v = key;
                    v.deinit(self.allocator, self.stack_alloc);
                    return error.StackUnderflow;
                };
                var key_val = key;
                var container_val = container;
                key_val.deinit(self.allocator, self.stack_alloc);
                container_val.deinit(self.allocator, self.stack_alloc);
            },
            .DELETE_SLICE_0, .DELETE_SLICE_1, .DELETE_SLICE_2, .DELETE_SLICE_3 => {
                // Legacy DELETE_SLICE+* (Python 2.x)
                const container = switch (inst.opcode) {
                    .DELETE_SLICE_0 => self.stack.pop() orelse return error.StackUnderflow,
                    .DELETE_SLICE_1 => blk: {
                        const start = self.stack.pop() orelse return error.StackUnderflow;
                        const cont = self.stack.pop() orelse {
                            var v = start;
                            v.deinit(self.allocator, self.stack_alloc);
                            return error.StackUnderflow;
                        };
                        var start_val = start;
                        start_val.deinit(self.allocator, self.stack_alloc);
                        break :blk cont;
                    },
                    .DELETE_SLICE_2 => blk: {
                        const stop = self.stack.pop() orelse return error.StackUnderflow;
                        const cont = self.stack.pop() orelse {
                            var v = stop;
                            v.deinit(self.allocator, self.stack_alloc);
                            return error.StackUnderflow;
                        };
                        var stop_val = stop;
                        stop_val.deinit(self.allocator, self.stack_alloc);
                        break :blk cont;
                    },
                    .DELETE_SLICE_3 => blk: {
                        const stop = self.stack.pop() orelse return error.StackUnderflow;
                        const start = self.stack.pop() orelse {
                            var v = stop;
                            v.deinit(self.allocator, self.stack_alloc);
                            return error.StackUnderflow;
                        };
                        const cont = self.stack.pop() orelse {
                            var v = start;
                            v.deinit(self.allocator, self.stack_alloc);
                            return error.StackUnderflow;
                        };
                        var stop_val = stop;
                        stop_val.deinit(self.allocator, self.stack_alloc);
                        var start_val = start;
                        start_val.deinit(self.allocator, self.stack_alloc);
                        break :blk cont;
                    },
                    else => unreachable,
                };
                var container_val = container;
                container_val.deinit(self.allocator, self.stack_alloc);
            },
            .DELETE_ATTR => {
                // DELETE_ATTR namei - delete attribute from TOS
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
            },

            .EXEC_STMT => {
                // EXEC_STMT (Python 2.x) - pops code, globals, locals
                const locals_val = self.stack.pop() orelse return error.StackUnderflow;
                const globals_val = self.stack.pop() orelse {
                    var v = locals_val;
                    v.deinit(self.allocator, self.stack_alloc);
                    return error.StackUnderflow;
                };
                const code_val = self.stack.pop() orelse {
                    var v = locals_val;
                    v.deinit(self.allocator, self.stack_alloc);
                    var g = globals_val;
                    g.deinit(self.allocator, self.stack_alloc);
                    return error.StackUnderflow;
                };
                var l = locals_val;
                var g = globals_val;
                var c = code_val;
                l.deinit(self.allocator, self.stack_alloc);
                g.deinit(self.allocator, self.stack_alloc);
                c.deinit(self.allocator, self.stack_alloc);
            },

            .CONVERT_VALUE => {
                // CONVERT_VALUE conversion - applies str/repr/ascii to TOS
                // arg: 1=str(), 2=repr(), 3=ascii()
                const value = try self.stack.popExpr();
                errdefer {
                    value.deinit(self.allocator);
                    self.allocator.destroy(value);
                }

                const conv: u8 = switch (inst.arg) {
                    1 => 's',
                    2 => 'r',
                    3 => 'a',
                    else => 's',
                };

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .formatted_value = .{
                    .value = value,
                    .conversion = conv,
                    .format_spec = null,
                } };
                try self.stack.push(.{ .expr = expr });
            },

            // Format string opcodes
            .FORMAT_SIMPLE => {
                // FORMAT_SIMPLE - format TOS for f-string (no conversion, no format spec)
                // If TOS is already formatted_value (from CONVERT_VALUE), just pass through
                const value = try self.stack.popExpr();
                if (value.* == .formatted_value) {
                    try self.stack.push(.{ .expr = value });
                } else {
                    errdefer {
                        value.deinit(self.allocator);
                        self.allocator.destroy(value);
                    }

                    const expr = try self.allocator.create(Expr);
                    expr.* = .{ .formatted_value = .{
                        .value = value,
                        .conversion = null,
                        .format_spec = null,
                    } };
                    try self.stack.push(.{ .expr = expr });
                }
            },

            .FORMAT_WITH_SPEC => {
                // FORMAT_WITH_SPEC - format value with format spec from stack
                const format_spec = try self.stack.popExpr();
                errdefer {
                    format_spec.deinit(self.allocator);
                    self.allocator.destroy(format_spec);
                }

                const value = try self.stack.popExpr();
                errdefer {
                    value.deinit(self.allocator);
                    self.allocator.destroy(value);
                }

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .formatted_value = .{
                    .value = value,
                    .conversion = null,
                    .format_spec = format_spec,
                } };
                try self.stack.push(.{ .expr = expr });
            },

            .FORMAT_VALUE => {
                // FORMAT_VALUE flags - format TOS for f-string
                // flags & 0x03: conversion (0=none, 1=str, 2=repr, 3=ascii)
                // flags & 0x04: format spec on stack
                const has_spec = (inst.arg & 0x04) != 0;
                var format_spec: ?*Expr = null;
                if (has_spec) {
                    format_spec = try self.stack.popExpr();
                }
                errdefer if (format_spec) |spec| {
                    spec.deinit(self.allocator);
                    self.allocator.destroy(spec);
                };

                const value = try self.stack.popExpr();
                errdefer {
                    value.deinit(self.allocator);
                    self.allocator.destroy(value);
                }

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

            // Boolean operations (short-circuit evaluation).
            // Stack effect depends on control flow; leave value on stack and let CFG edges
            // account for the pop-on-fallthrough behavior.
            .JUMP_IF_TRUE_OR_POP, .JUMP_IF_FALSE_OR_POP => {},

            .JUMP_IF_TRUE, .JUMP_IF_FALSE => {
                // Python 3.0 only: jump if true/false, value stays on stack
                // Control flow is handled by the CFG, just leave value on stack
            },

            .TO_BOOL => {
                // Preserve the existing expression for decompilation.
            },

            .POP_JUMP_IF_TRUE,
            .POP_JUMP_IF_FALSE,
            .POP_JUMP_IF_NONE,
            .POP_JUMP_IF_NOT_NONE,
            .POP_JUMP_FORWARD_IF_TRUE,
            .POP_JUMP_FORWARD_IF_FALSE,
            .POP_JUMP_FORWARD_IF_NONE,
            .POP_JUMP_FORWARD_IF_NOT_NONE,
            .POP_JUMP_BACKWARD_IF_TRUE,
            .POP_JUMP_BACKWARD_IF_FALSE,
            .POP_JUMP_BACKWARD_IF_NONE,
            .POP_JUMP_BACKWARD_IF_NOT_NONE,
            => {
                const cond = try self.stack.popExpr();
                if (self.enable_ifexp) {
                    const target = inst.jumpTarget(self.version) orelse inst.arg;
                    if (target > inst.offset) {
                        var final_cond = switch (inst.opcode) {
                            .POP_JUMP_IF_TRUE,
                            .POP_JUMP_FORWARD_IF_TRUE,
                            .POP_JUMP_BACKWARD_IF_TRUE,
                            => try ast.makeUnaryOp(self.allocator, .not_, cond),
                            .POP_JUMP_IF_NONE,
                            .POP_JUMP_FORWARD_IF_NONE,
                            .POP_JUMP_BACKWARD_IF_NONE,
                            => try self.makeIsNoneCompare(cond, true),
                            .POP_JUMP_IF_NOT_NONE,
                            .POP_JUMP_FORWARD_IF_NOT_NONE,
                            .POP_JUMP_BACKWARD_IF_NOT_NONE,
                            => try self.makeIsNoneCompare(cond, false),
                            else => cond,
                        };
                        errdefer {
                            final_cond.deinit(self.allocator);
                            self.allocator.destroy(final_cond);
                        }
                        try self.pending_ifexp.append(self.stack_alloc, .{
                            .false_target = target,
                            .merge_target = null,
                            .condition = final_cond,
                            .then_expr = null,
                        });
                        return;
                    }
                }
                if (self.findActiveCompBuilder()) |builder| {
                    // For comprehension filters, both old and new patterns result in
                    // "include when condition is truthy":
                    // - Old: POP_JUMP_IF_FALSE to skip, fall through to include -> include on TRUE
                    // - 3.14: POP_JUMP_IF_TRUE to include -> include on TRUE
                    // So we use the condition as-is for TRUE jumps and negate for FALSE jumps
                    const final_cond = switch (inst.opcode) {
                        .POP_JUMP_IF_FALSE,
                        .POP_JUMP_FORWARD_IF_FALSE,
                        .POP_JUMP_BACKWARD_IF_FALSE,
                        => cond, // FALSE jumps to skip, TRUE falls through to include
                        .POP_JUMP_IF_TRUE,
                        .POP_JUMP_FORWARD_IF_TRUE,
                        .POP_JUMP_BACKWARD_IF_TRUE,
                        => cond, // Python 3.14: TRUE jumps to include
                        .POP_JUMP_IF_NONE,
                        .POP_JUMP_FORWARD_IF_NONE,
                        .POP_JUMP_BACKWARD_IF_NONE,
                        => try self.makeIsNoneCompare(cond, true),
                        .POP_JUMP_IF_NOT_NONE,
                        .POP_JUMP_FORWARD_IF_NOT_NONE,
                        .POP_JUMP_BACKWARD_IF_NOT_NONE,
                        => try self.makeIsNoneCompare(cond, false),
                        else => cond,
                    };
                    errdefer {
                        final_cond.deinit(self.allocator);
                        self.allocator.destroy(final_cond);
                    }
                    try self.addCompIf(builder, final_cond);
                    return;
                }

                cond.deinit(self.allocator);
                self.allocator.destroy(cond);
            },

            // Yield opcodes
            .GET_YIELD_FROM_ITER => {
                // GET_YIELD_FROM_ITER - prepare iterator for yield from
                // TOS is the iterable, result is the iterator
            },

            .GEN_START => {
                // GEN_START - pops the sent value (None on first call)
                // In decompilation, we start with empty stack, so just ignore
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
            },

            .YIELD_VALUE => {
                // YIELD_VALUE - yield TOS
                // In await loop (pending_await), just pop/push unknown
                if (self.pending_await) {
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    }
                    try self.stack.push(.unknown);
                    return;
                }

                const value = self.stack.popExpr() catch |err| {
                    if (self.lenient or self.flow_mode) {
                        // If we can't get an expr, push unknown and continue (2.5+)
                        if (self.version.gte(2, 5)) {
                            _ = self.stack.pop();
                            try self.stack.push(.unknown);
                        }
                        return;
                    }
                    return err;
                };

                if (self.comp_builder) |builder| {
                    if (builder.kind == .genexpr) {
                        if (builder.elt) |old| {
                            old.deinit(self.allocator);
                            self.allocator.destroy(old);
                        }
                        builder.elt = value;
                        builder.seen_append = true;
                        try self.stack.push(.unknown);
                        return;
                    }
                }

                // Pre-2.5 generators cannot receive a value, so yield does not push.
                if (self.version.lt(2, 5)) {
                    value.deinit(self.allocator);
                    self.allocator.destroy(value);
                    return;
                }

                errdefer {
                    value.deinit(self.allocator);
                    self.allocator.destroy(value);
                }
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .yield_expr = .{ .value = value } };
                try self.stack.push(.{ .expr = expr });
            },

            .YIELD_FROM => {
                // YIELD_FROM - yield from iterable, or await if preceded by GET_AWAITABLE
                const send_val = try self.stack.popExpr();

                // Check if this is an await (GET_AWAITABLE was seen)
                if (self.pending_await) {
                    self.pending_await = false;
                    // Get the awaitable from stack (GET_AWAITABLE left it there)
                    const awaitable = try self.stack.popExpr();
                    // Discard the None value from LOAD_CONST
                    send_val.deinit(self.allocator);
                    self.allocator.destroy(send_val);
                    // Create await expression
                    const expr = try self.allocator.create(Expr);
                    expr.* = .{ .await_expr = .{ .value = awaitable } };
                    try self.stack.push(.{ .expr = expr });
                } else {
                    const iter_val = try self.stack.popExpr();
                    send_val.deinit(self.allocator);
                    self.allocator.destroy(send_val);
                    const expr = try self.allocator.create(Expr);
                    expr.* = .{ .yield_from = .{ .value = iter_val } };
                    try self.stack.push(.{ .expr = expr });
                }
            },

            .SEND => {
                // SEND delta - send value to generator
                // TOS is the value to send, TOS1 is the generator
                // Pop value, push result; generator stays at TOS1
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                }
                // Generator stays, received value pushed
                try self.stack.push(.unknown);
            },

            .END_SEND => {
                // END_SEND - end of await/yield from
                // Stack: [awaitable/iterator, value] -> [value]
                // Pop value (last received), pop awaitable, push final value
                const value = self.stack.pop();
                const awaitable = self.stack.pop();

                if (self.pending_await) {
                    self.pending_await = false;
                    // Create await expression
                    if (awaitable) |aw| {
                        if (aw == .expr) {
                            const expr = try self.allocator.create(Expr);
                            expr.* = .{ .await_expr = .{ .value = aw.expr } };
                            try self.stack.push(.{ .expr = expr });
                            // Discard the value
                            if (value) |v| {
                                var val = v;
                                val.deinit(self.allocator, self.stack_alloc);
                            }
                            return;
                        }
                    }
                }
                // Not an await - push value (or unknown if nothing)
                if (value) |v| {
                    try self.stack.push(v);
                } else {
                    try self.stack.push(.unknown);
                }
                // Clean up awaitable if not used
                if (awaitable) |aw| {
                    var awv = aw;
                    awv.deinit(self.allocator, self.stack_alloc);
                }
            },

            .CLEANUP_THROW => {
                // CLEANUP_THROW (3.11+) - cleanup during SEND/await exception path.
                // Stack effect: -1 (drops an exception/why marker, leaving [awaitable, value] for loop-back).
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else if (!(self.lenient or self.flow_mode)) {
                    return error.StackUnderflow;
                }
            },

            // Comprehension opcodes
            .LIST_APPEND => {
                // LIST_APPEND i - append TOS to list at STACK[-i]
                // Used in list comprehensions
                // Python: v = POP(); list = PEEK(i); list.append(v)
                // After popping item, PEEK(i) uses depth i from new stack
                if (self.lenient) {
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    }
                    return;
                }
                const item = try self.stack.popExpr();
                var item_owned = true;
                errdefer if (item_owned) {
                    item.deinit(self.allocator);
                    self.allocator.destroy(item);
                };

                if (self.comp_builder) |b| {
                    if (b.kind != .list) return error.InvalidComprehension;
                    if (b.elt) |old| {
                        old.deinit(self.allocator);
                        self.allocator.destroy(old);
                    }
                    b.elt = item;
                    b.seen_append = true;
                    item_owned = false;
                    return;
                }
                if (self.findCompContainer()) |container| {
                    const builder = try self.ensureCompBuilderAt(container.idx, container.kind);
                    if (builder.kind != .list) return error.InvalidComprehension;
                    if (builder.elt) |old| {
                        old.deinit(self.allocator);
                        self.allocator.destroy(old);
                    }
                    builder.elt = item;
                    builder.seen_append = true;
                    item_owned = false;
                    return;
                }

                const list_idx = try self.stackIndexFromDepth(inst.arg);
                const list_val = self.stack.items.items[list_idx];
                if (list_val != .expr or list_val.expr.* != .list) return error.NotAnExpression;
                const list_expr = list_val.expr;
                const old_len = list_expr.list.elts.len;
                const new_elts = try self.allocator.alloc(*Expr, old_len + 1);
                if (old_len > 0) {
                    @memcpy(new_elts[0..old_len], list_expr.list.elts);
                    self.allocator.free(list_expr.list.elts);
                }
                new_elts[old_len] = item;
                list_expr.list.elts = new_elts;
                item_owned = false;
            },

            .SET_ADD => {
                // SET_ADD i - add TOS to set at STACK[-i]
                // Used in set comprehensions
                // Python: v = POP(); set = PEEK(i); set.add(v)
                if (self.lenient) {
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    }
                    return;
                }
                const item = try self.stack.popExpr();
                const builder = if (self.comp_builder) |b| blk: {
                    if (b.kind != .set) return error.InvalidComprehension;
                    break :blk b;
                } else try self.getBuilderAtDepth(inst.arg, .set);
                if (builder.elt) |old| {
                    old.deinit(self.allocator);
                    self.allocator.destroy(old);
                }
                builder.elt = item;
                builder.seen_append = true;
            },

            .MAP_ADD => {
                // MAP_ADD i - add TOS1:TOS to dict at STACK[-i]
                // Used in dict comprehensions
                // Python: v = POP(); k = POP(); dict = PEEK(i); dict[k] = v
                // After popping both, PEEK(i) uses depth i from new stack
                if (self.lenient) {
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    }
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator, self.stack_alloc);
                    }
                    return;
                }
                const value = try self.stack.popExpr();
                errdefer {
                    value.deinit(self.allocator);
                    self.allocator.destroy(value);
                }
                const key = try self.stack.popExpr();
                const builder = if (self.comp_builder) |b| blk: {
                    if (b.kind != .dict) return error.InvalidComprehension;
                    break :blk b;
                } else try self.getBuilderAtDepth(inst.arg, .dict);
                if (builder.key) |old_key| {
                    old_key.deinit(self.allocator);
                    self.allocator.destroy(old_key);
                }
                if (builder.value) |old_value| {
                    old_value.deinit(self.allocator);
                    self.allocator.destroy(old_value);
                }
                builder.key = key;
                builder.value = value;
                builder.seen_append = true;
            },

            .LIST_EXTEND => {
                // LIST_EXTEND i - extend list at stack[i] with TOS
                // Pattern: BUILD_LIST 0 + LOAD_CONST(tuple) + LIST_EXTEND 1 → [elements...]
                const items = self.stack.pop() orelse return error.StackUnderflow;

                const list_idx = try self.stackIndexFromDepth(inst.arg);
                const list_val = self.stack.items.items[list_idx];
                if (list_val != .expr or list_val.expr.* != .list) {
                    return error.NotAnExpression;
                }
                const list_expr = list_val.expr;

                if (items == .expr) {
                    const tuple_expr = items.expr;
                    switch (tuple_expr.*) {
                        .tuple => |tup| {
                            const tuple_elts = tup.elts;
                            tuple_expr.tuple.elts = &.{};
                            defer {
                                tuple_expr.deinit(self.allocator);
                                self.allocator.destroy(tuple_expr);
                            }

                            if (tuple_elts.len == 0) return;

                            const old_len = list_expr.list.elts.len;
                            if (old_len == 0) {
                                list_expr.list.elts = tuple_elts;
                                return;
                            }

                            const new_elts = try self.allocator.alloc(*Expr, old_len + tuple_elts.len);
                            @memcpy(new_elts[0..old_len], list_expr.list.elts);
                            @memcpy(new_elts[old_len..], tuple_elts);
                            self.allocator.free(list_expr.list.elts);
                            if (tuple_elts.len > 0) self.allocator.free(tuple_elts);
                            list_expr.list.elts = new_elts;
                            return;
                        },
                        .constant => |c| switch (c) {
                            .tuple => |items_const| {
                                const tuple_elts = try self.allocator.alloc(*Expr, items_const.len);
                                var count: usize = 0;
                                errdefer {
                                    var i: usize = 0;
                                    while (i < count) : (i += 1) {
                                        tuple_elts[i].deinit(self.allocator);
                                        self.allocator.destroy(tuple_elts[i]);
                                    }
                                    self.allocator.free(tuple_elts);
                                }

                                for (items_const, 0..) |item, idx| {
                                    const cloned = try ast.cloneConstant(self.allocator, item);
                                    const expr = try ast.makeConstant(self.allocator, cloned);
                                    tuple_elts[idx] = expr;
                                    count += 1;
                                }

                                tuple_expr.deinit(self.allocator);
                                self.allocator.destroy(tuple_expr);

                                if (tuple_elts.len == 0) {
                                    self.allocator.free(tuple_elts);
                                    return;
                                }

                                const old_len = list_expr.list.elts.len;
                                if (old_len == 0) {
                                    list_expr.list.elts = tuple_elts;
                                    return;
                                }

                                const new_elts = try self.allocator.alloc(*Expr, old_len + tuple_elts.len);
                                @memcpy(new_elts[0..old_len], list_expr.list.elts);
                                @memcpy(new_elts[old_len..], tuple_elts);
                                self.allocator.free(list_expr.list.elts);
                                self.allocator.free(tuple_elts);
                                list_expr.list.elts = new_elts;
                                return;
                            },
                            else => {},
                        },
                        else => {},
                    }
                }

                const item_expr = switch (items) {
                    .expr => |expr| expr,
                    else => return error.NotAnExpression,
                };

                const starred = try ast.makeStarred(self.allocator, item_expr, .load);
                const old_len = list_expr.list.elts.len;
                const new_elts = try self.allocator.alloc(*Expr, old_len + 1);
                if (old_len > 0) {
                    @memcpy(new_elts[0..old_len], list_expr.list.elts);
                    self.allocator.free(list_expr.list.elts);
                }
                new_elts[old_len] = starred;
                list_expr.list.elts = new_elts;
            },

            .SET_UPDATE => {
                // SET_UPDATE i - update set at stack[i] with TOS
                const items = self.stack.pop() orelse return error.StackUnderflow;
                const set_idx = try self.stackIndexFromDepth(inst.arg);
                const set_val = self.stack.items.items[set_idx];
                if (set_val != .expr or set_val.expr.* != .set) {
                    var val = items;
                    val.deinit(self.allocator, self.stack_alloc);
                    return error.NotAnExpression;
                }
                const set_expr = set_val.expr;

                if (items == .expr) {
                    switch (items.expr.*) {
                        .tuple => |*t| {
                            const elts = t.elts;
                            t.elts = &.{};
                            items.expr.deinit(self.allocator);
                            self.allocator.destroy(items.expr);
                            try self.appendSetElts(set_expr, elts);
                            return;
                        },
                        .list => |*l| {
                            const elts = l.elts;
                            l.elts = &.{};
                            items.expr.deinit(self.allocator);
                            self.allocator.destroy(items.expr);
                            try self.appendSetElts(set_expr, elts);
                            return;
                        },
                        .set => |*s| {
                            const elts = s.elts;
                            s.elts = &.{};
                            s.cap = 0;
                            items.expr.deinit(self.allocator);
                            self.allocator.destroy(items.expr);
                            try self.appendSetElts(set_expr, elts);
                            return;
                        },
                        .call => |c| {
                            if (c.func.* == .name and std.mem.eql(u8, c.func.name.id, "frozenset") and c.args.len == 1) {
                                const arg0 = c.args[0];
                                switch (arg0.*) {
                                    .tuple => |*t| {
                                        const elts = t.elts;
                                        t.elts = &.{};
                                        items.expr.deinit(self.allocator);
                                        self.allocator.destroy(items.expr);
                                        try self.appendSetElts(set_expr, elts);
                                        return;
                                    },
                                    .list => |*l| {
                                        const elts = l.elts;
                                        l.elts = &.{};
                                        items.expr.deinit(self.allocator);
                                        self.allocator.destroy(items.expr);
                                        try self.appendSetElts(set_expr, elts);
                                        return;
                                    },
                                    .set => |*s| {
                                        const elts = s.elts;
                                        s.elts = &.{};
                                        s.cap = 0;
                                        items.expr.deinit(self.allocator);
                                        self.allocator.destroy(items.expr);
                                        try self.appendSetElts(set_expr, elts);
                                        return;
                                    },
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                }

                const item_expr = switch (items) {
                    .expr => |expr| expr,
                    else => {
                        var val = items;
                        val.deinit(self.allocator, self.stack_alloc);
                        return error.NotAnExpression;
                    },
                };
                const starred = try ast.makeStarred(self.allocator, item_expr, .load);
                try self.appendSetElt(set_expr, starred);
            },

            .DICT_UPDATE => {
                // DICT_UPDATE i - update dict at stack[i] with TOS
                const update_val = self.stack.pop() orelse return error.StackUnderflow;
                errdefer update_val.deinit(self.allocator, self.stack_alloc);

                const idx: usize = @intCast(inst.arg);
                if (idx > self.stack.items.items.len) return error.StackUnderflow;
                const dict_idx = self.stack.items.items.len - idx;

                if (self.stack.items.items[dict_idx] == .expr and
                    self.stack.items.items[dict_idx].expr.* == .dict and
                    update_val == .expr)
                {
                    try self.appendDictMerge(self.stack.items.items[dict_idx].expr, update_val.expr);
                } else {
                    update_val.deinit(self.allocator, self.stack_alloc);
                }
            },

            .COPY_DICT_WITHOUT_KEYS => {
                // COPY_DICT_WITHOUT_KEYS - remove keys tuple from a dict copy
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
                try self.stack.push(.unknown);
            },

            .DICT_MERGE => {
                // DICT_MERGE i - merge TOS into dict at stack[i]
                const update_val = self.stack.pop() orelse return error.StackUnderflow;
                errdefer update_val.deinit(self.allocator, self.stack_alloc);

                const idx: usize = @intCast(inst.arg);
                if (idx > self.stack.items.items.len) return error.StackUnderflow;
                const dict_idx = self.stack.items.items.len - idx;

                if (self.stack.items.items[dict_idx] == .expr and
                    self.stack.items.items[dict_idx].expr.* == .dict and
                    update_val == .expr)
                {
                    try self.appendDictMerge(self.stack.items.items[dict_idx].expr, update_val.expr);
                } else {
                    update_val.deinit(self.allocator, self.stack_alloc);
                }
            },

            // Await expression
            .GET_AWAITABLE => {
                // GET_AWAITABLE - get awaitable from TOS
                // Set flag so YIELD_FROM creates await expression
                self.pending_await = true;
            },

            .GET_AITER => {
                // GET_AITER - get async iterator from TOS
                // Pops iterable, pushes async iterator
                // Stack effect: 0 (pop 1, push 1)
            },

            .GET_ANEXT => {
                // GET_ANEXT - get next awaitable from async iterator
                // Stack effect: +1 (pushes awaitable, iterator stays)
                self.pending_await = true;
                try self.stack.push(.unknown);
            },

            .END_ASYNC_FOR => {
                // END_ASYNC_FOR - cleanup after async for loop
                // Pops (exc_type, exc, tb) + async iterator on legacy versions.
                const exc_drop: usize = if (self.version.gte(3, 11)) 1 else 3;
                const total_drop: usize = exc_drop + 1;
                var i: usize = 0;
                while (i < total_drop) : (i += 1) {
                    if (self.stack.pop()) |v| {
                        if (!self.flow_mode) {
                            var val = v;
                            val.deinit(self.allocator, self.stack_alloc);
                        }
                    } else if (!(self.lenient or self.flow_mode)) {
                        return error.StackUnderflow;
                    } else {
                        break;
                    }
                }
            },

            .END_FOR => {
                if (self.findActiveCompBuilder()) |builder| {
                    if (builder.loop_stack.items.len > 0) {
                        _ = builder.loop_stack.pop();
                    }
                    if (builder.loop_stack.items.len == 0 and builder.seen_append) {
                        if (self.isBuilderOnStack(builder)) {
                            const expr = try self.buildCompExpr(builder);
                            for (self.stack.items.items, 0..) |item, idx| {
                                if (item == .comp_builder and item.comp_builder == builder) {
                                    self.stack.items.items[idx] = .{ .expr = expr };
                                    break;
                                }
                            }
                            builder.deinit(self.allocator, self.stack_alloc);
                        }
                    }
                }
                // Python 3.14+: END_FOR is a marker; POP_ITER pops the iterator.
                if (self.version.gte(3, 14)) return;
                // Python <=3.13: END_FOR cleans up the iterator on loop exit.
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else if (!(self.lenient or self.flow_mode)) {
                    return error.StackUnderflow;
                }
            },

            .POP_ITER => {
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
            },

            .UNPACK_EX => {
                // UNPACK_EX - unpack with *rest
                // Low byte: before star, high byte: after star
                const before = inst.arg & 0xFF;
                const after = (inst.arg >> 8) & 0xFF;
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
                var i: u32 = 0;
                while (i < before + 1 + after) : (i += 1) {
                    try self.stack.push(.unknown);
                }
            },

            // Pattern matching opcodes (Python 3.10+)
            .MATCH_SEQUENCE => {
                // Stack effect +1: push bool (subject stays on stack)
                try self.stack.push(.unknown);
            },

            .MATCH_MAPPING => {
                // Stack effect +1: push bool (subject stays on stack)
                try self.stack.push(.unknown);
            },

            .MATCH_KEYS => {
                // Stack effect +1: push values tuple or None (subject + keys stay)
                try self.stack.push(.unknown);
            },

            .MATCH_CLASS => {
                // Stack effect -2: pop attr_names, class, subject (3); push result (1)
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
                try self.stack.push(.unknown); // attrs tuple or None
            },

            .GET_LEN => {
                // Stack effect +1: push len(TOS), TOS stays
                try self.stack.push(.unknown);
            },

            // Python 2.x print statement opcodes
            .PRINT_ITEM => {
                // Pop and print value - handled at decompile level
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
            },

            .PRINT_NEWLINE => {
                // Print newline - no stack effect
            },

            .PRINT_ITEM_TO => {
                // Pop value and file object, print value to file
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
                // Note: file object should already be on stack from earlier LOAD
            },

            .PRINT_NEWLINE_TO => {
                // Pop file object, print newline to it
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator, self.stack_alloc);
                } else {
                    return error.StackUnderflow;
                }
            },

            .UNPACK_SEQUENCE => {
                // Pop sequence, push N elements as unpack markers
                // Handled at decompile level to detect unpacking pattern
                const count = inst.arg;
                try self.startCompUnpack(count);
                const seq = self.stack.pop() orelse blk: {
                    if (self.lenient or self.flow_mode) break :blk .unknown;
                    return error.StackUnderflow;
                };
                _ = seq;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    try self.stack.push(.unknown);
                }
            },

            .CALL_INTRINSIC_1 => {
                // Pops 1 arg, pushes result (net: 0)
                // IDs: 3=STOPITERATION_ERROR, 7=TYPEVAR, 11=TYPEALIAS
                const arg = self.stack.pop() orelse return error.StackUnderflow;

                if (inst.arg == 11) { // INTRINSIC_TYPEALIAS
                    // arg is a tuple (name, type_params, value_func)
                    // value_func code contains the type expression
                    if (arg == .expr and arg.expr.* == .tuple and arg.expr.tuple.elts.len == 3) {
                        const elts = arg.expr.tuple.elts;
                        const name_expr = elts[0];
                        const value_func = elts[2];

                        // Convert name constant to Name expression
                        const final_name = if (name_expr.* == .constant and name_expr.constant == .string) blk: {
                            const name_node = try self.allocator.create(Expr);
                            name_node.* = .{ .name = .{ .id = name_expr.constant.string, .ctx = .store } };
                            break :blk name_node;
                        } else name_expr;

                        // Try to extract type value from the value function
                        // The value_func is created from MAKE_FUNCTION and may contain code
                        // that evaluates to the type expression
                        const final_value = if (value_func.* == .constant and value_func.constant == .ellipsis) blk: {
                            // Placeholder - keep as is
                            break :blk value_func;
                        } else value_func;

                        // Create a type_alias_marker tuple for the decompiler
                        const marker = try self.allocator.create(Expr);
                        const marker_elts = try self.allocator.alloc(*Expr, 2);
                        marker_elts[0] = final_name;
                        marker_elts[1] = final_value;
                        marker.* = .{ .tuple = .{
                            .elts = marker_elts,
                            .ctx = .load,
                        } };
                        if (arg.expr.* == .tuple) {
                            if (arg.expr.tuple.elts.len > 0) self.allocator.free(arg.expr.tuple.elts);
                        }
                        self.allocator.destroy(arg.expr);
                        try self.stack.push(.{ .type_alias = marker });
                    } else {
                        arg.deinit(self.allocator, self.stack_alloc);
                        try self.stack.push(.unknown);
                    }
                } else {
                    arg.deinit(self.allocator, self.stack_alloc);
                    try self.stack.push(.unknown);
                }
            },

            .CALL_INTRINSIC_2 => {
                // Pops 2 args, pushes result (net: -1)
                // IDs: 1=PREP_RERAISE_STAR, 4=SET_FUNCTION_TYPE_PARAMS
                _ = self.stack.pop() orelse return error.StackUnderflow;
                _ = self.stack.pop() orelse return error.StackUnderflow;
                try self.stack.push(.unknown);
            },

            else => {
                // Unhandled opcode - push unknown for each value it would produce
                // For now, just push unknown
                try self.stack.push(.unknown);
            },
        }
        self.prev_opcode = inst.opcode;
    }
};

pub const PendingBoolOp = struct {
    target: u32,
    op: ast.BoolOp,
    left: *Expr,
    chain_compare: bool,
};

const PendingIfExp = struct {
    false_target: u32,
    merge_target: ?u32,
    condition: *Expr,
    then_expr: ?*Expr,

    fn deinit(self: *PendingIfExp, allocator: Allocator) void {
        self.condition.deinit(allocator);
        allocator.destroy(self.condition);
        if (self.then_expr) |expr| {
            expr.deinit(allocator);
            allocator.destroy(expr);
        }
    }
};

fn makeBoolPair(allocator: Allocator, left: *Expr, right: *Expr, op: ast.BoolOp) !*Expr {
    const values = try allocator.alloc(*Expr, 2);
    errdefer allocator.free(values);
    values[0] = left;
    values[1] = right;

    const expr = try allocator.create(Expr);
    errdefer allocator.destroy(expr);
    expr.* = .{ .bool_op = .{ .op = op, .values = values } };
    return expr;
}

fn tryMergeCompareChain(allocator: Allocator, left: *Expr, right: *Expr) !?*Expr {
    if (left.* != .compare or right.* != .compare) return null;
    const l = left.compare;
    const r = right.compare;
    if (l.comparators.len == 0 or r.comparators.len == 0) return null;
    const last = l.comparators[l.comparators.len - 1];
    if (!ast.exprEqual(last, r.left)) return null;

    const ops = try allocator.alloc(ast.CmpOp, l.ops.len + r.ops.len);
    errdefer allocator.free(ops);
    const comps = try allocator.alloc(*Expr, l.comparators.len + r.comparators.len);
    errdefer allocator.free(comps);
    std.mem.copyForwards(ast.CmpOp, ops[0..l.ops.len], l.ops);
    std.mem.copyForwards(ast.CmpOp, ops[l.ops.len..], r.ops);
    std.mem.copyForwards(*Expr, comps[0..l.comparators.len], l.comparators);
    std.mem.copyForwards(*Expr, comps[l.comparators.len..], r.comparators);

    const expr = try allocator.create(Expr);
    errdefer allocator.destroy(expr);
    expr.* = .{ .compare = .{ .left = l.left, .ops = ops, .comparators = comps } };
    return expr;
}

fn makeIfExp(allocator: Allocator, condition: *Expr, body: *Expr, else_body: *Expr) !*Expr {
    const expr = try allocator.create(Expr);
    errdefer allocator.destroy(expr);
    expr.* = .{ .if_exp = .{
        .condition = condition,
        .body = body,
        .else_body = else_body,
    } };
    return expr;
}

fn resolveIfExps(
    allocator: Allocator,
    stack: *Stack,
    pending: *std.ArrayListUnmanaged(PendingIfExp),
    offset: u32,
) !bool {
    if (pending.items.len == 0) return false;
    var found = false;
    var i: usize = pending.items.len;
    while (i > 0) {
        i -= 1;
        if (pending.items[i].merge_target != null and pending.items[i].merge_target.? == offset) {
            found = true;
            break;
        }
    }
    if (!found) return false;

    var expr = try stack.popExpr();
    var cleanup_expr: ?*Expr = expr;
    errdefer {
        if (cleanup_expr) |e| {
            e.deinit(allocator);
            allocator.destroy(e);
        }
    }

    i = pending.items.len;
    while (i > 0) {
        i -= 1;
        if (pending.items[i].merge_target == null or pending.items[i].merge_target.? != offset) continue;
        const item = pending.items[i];
        const then_expr = item.then_expr orelse return error.InvalidTernary;
        const if_expr = try makeIfExp(allocator, item.condition, then_expr, expr);
        expr = if_expr;
        cleanup_expr = expr;

        const len = pending.items.len;
        if (i + 1 < len) {
            std.mem.copyForwards(PendingIfExp, pending.items[i .. len - 1], pending.items[i + 1 .. len]);
        }
        pending.items.len -= 1;
    }

    try stack.push(.{ .expr = expr });
    cleanup_expr = null;
    return true;
}

fn captureIfExpThen(
    stack: *Stack,
    pending: *std.ArrayListUnmanaged(PendingIfExp),
    offset: u32,
    merge_target: u32,
) !bool {
    if (pending.items.len == 0) return false;
    var idx: ?usize = null;
    var i: usize = pending.items.len;
    while (i > 0) {
        i -= 1;
        const item = pending.items[i];
        if (item.merge_target == null and item.false_target > offset) {
            idx = i;
            break;
        }
    }
    if (idx == null) return false;

    const then_expr = try stack.popExpr();
    errdefer {
        then_expr.deinit(stack.ast_alloc);
        stack.ast_alloc.destroy(then_expr);
    }

    pending.items[idx.?].then_expr = then_expr;
    pending.items[idx.?].merge_target = merge_target;
    return true;
}

pub fn resolveBoolOps(
    allocator: Allocator,
    stack: *Stack,
    pending: *std.ArrayListUnmanaged(PendingBoolOp),
    offset: u32,
) !bool {
    if (pending.items.len == 0) return false;
    var found = false;
    var i: usize = pending.items.len;
    while (i > 0) {
        i -= 1;
        if (pending.items[i].target == offset) {
            found = true;
            break;
        }
    }
    if (!found) return false;

    var expr = try stack.popExpr();
    i = pending.items.len;
    while (i > 0) {
        i -= 1;
        if (pending.items[i].target != offset) continue;
        const item = pending.items[i];
        if (item.op == .and_ and item.chain_compare) {
            if (try tryMergeCompareChain(allocator, item.left, expr)) |merged| {
                expr = merged;
            } else {
                expr = try makeBoolPair(allocator, item.left, expr, item.op);
            }
        } else {
            expr = try makeBoolPair(allocator, item.left, expr, item.op);
        }
        const len = pending.items.len;
        if (i + 1 < len) {
            std.mem.copyForwards(PendingBoolOp, pending.items[i .. len - 1], pending.items[i + 1 .. len]);
        }
        pending.items.len -= 1;
    }

    try stack.push(.{ .expr = expr });
    return true;
}

fn compKindFromName(name: []const u8) ?CompKind {
    if (std.mem.eql(u8, name, "<listcomp>")) return .list;
    if (std.mem.eql(u8, name, "<setcomp>")) return .set;
    if (std.mem.eql(u8, name, "<dictcomp>")) return .dict;
    if (std.mem.eql(u8, name, "<genexpr>")) return .genexpr;
    return null;
}

pub fn buildLambdaExpr(
    allocator: Allocator,
    code: *const pyc.Code,
    version: Version,
    defaults: []const *Expr,
    kw_defaults: []const ?*Expr,
) SimError!*Expr {
    var ctx = SimContext.init(allocator, allocator, code, version);
    defer ctx.deinit();
    ctx.enable_ifexp = true;

    var body_expr: ?*Expr = null;
    var pending: std.ArrayListUnmanaged(PendingBoolOp) = .{};
    defer pending.deinit(allocator);

    var iter = decoder.InstructionIterator.init(code.code, version);
    while (iter.next()) |inst| {
        _ = try resolveBoolOps(allocator, &ctx.stack, &pending, inst.offset);
        _ = try resolveIfExps(allocator, &ctx.stack, &ctx.pending_ifexp, inst.offset);
        switch (inst.opcode) {
            .RETURN_VALUE => {
                const ret_expr = try ctx.stack.popExpr();
                if (ctx.enable_ifexp and ctx.pending_ifexp.items.len > 0) {
                    var idx: ?usize = null;
                    var i: usize = ctx.pending_ifexp.items.len;
                    while (i > 0) {
                        i -= 1;
                        const item = ctx.pending_ifexp.items[i];
                        if (item.merge_target == null) {
                            idx = i;
                            break;
                        }
                    }
                    if (idx) |pi| {
                        var item = &ctx.pending_ifexp.items[pi];
                        if (item.then_expr == null and item.false_target > inst.offset) {
                            item.then_expr = ret_expr;
                            continue;
                        }
                        if (item.then_expr != null and item.false_target <= inst.offset) {
                            const if_expr = try makeIfExp(allocator, item.condition, item.then_expr.?, ret_expr);
                            const len = ctx.pending_ifexp.items.len;
                            if (pi + 1 < len) {
                                std.mem.copyForwards(PendingIfExp, ctx.pending_ifexp.items[pi .. len - 1], ctx.pending_ifexp.items[pi + 1 .. len]);
                            }
                            ctx.pending_ifexp.items.len -= 1;
                            body_expr = if_expr;
                            break;
                        }
                    }
                }
                body_expr = ret_expr;
                break;
            },
            .RETURN_CONST => {
                if (ctx.getConst(inst.arg)) |obj| {
                    body_expr = try ctx.objToExpr(obj);
                } else {
                    return error.InvalidConstant;
                }
                break;
            },
            .JUMP_IF_FALSE_OR_POP => {
                const left = try ctx.stack.popExpr();
                var chain_compare = false;
                if (left.* == .compare and left.compare.comparators.len > 0) {
                    if (ctx.stack.peek()) |val| {
                        if (val == .expr and ast.exprEqual(val.expr, left.compare.comparators[left.compare.comparators.len - 1])) {
                            chain_compare = true;
                        }
                    }
                }
                try pending.append(allocator, .{
                    .target = inst.arg,
                    .op = .and_,
                    .left = left,
                    .chain_compare = chain_compare,
                });
                continue;
            },
            .JUMP_IF_TRUE_OR_POP => {
                const left = try ctx.stack.popExpr();
                try pending.append(allocator, .{
                    .target = inst.arg,
                    .op = .or_,
                    .left = left,
                    .chain_compare = false,
                });
                continue;
            },
            else => try ctx.simulate(inst),
        }
    }

    const body = body_expr orelse return error.InvalidLambdaBody;
    errdefer {
        body.deinit(allocator);
        allocator.destroy(body);
    }

    const args = try signature.extractFunctionSignature(allocator, code, null, defaults, kw_defaults, &.{});
    errdefer {
        args.deinit(allocator);
        allocator.destroy(args);
    }

    const expr = try allocator.create(Expr);
    errdefer allocator.destroy(expr);
    expr.* = .{ .lambda = .{ .args = args, .body = body } };
    return expr;
}

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

/// Check if expression is a None constant.
fn isNoneExpr(expr: *const Expr) bool {
    return expr.* == .constant and expr.constant == .none;
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

    var ctx = SimContext.init(allocator, allocator, &code, version);
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

    // Clean up the expression since we're using testing.allocator, not an arena
    const popped = ctx.stack.pop().?;
    if (popped == .expr) {
        popped.expr.deinit(allocator);
        allocator.destroy(popped.expr);
    }
}

test "stack simulation dup top clones expr" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var consts = [_]pyc.Object{
        .{ .int = pyc.Int.fromI64(7) },
    };
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(3, 12);

    var ctx = SimContext.init(allocator, allocator, &code, version);
    defer ctx.deinit();

    const load_inst = Instruction{
        .opcode = .LOAD_CONST,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(load_inst);

    const dup_inst = Instruction{
        .opcode = .DUP_TOP,
        .arg = 0,
        .offset = 2,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(dup_inst);

    try testing.expectEqual(@as(usize, 2), ctx.stack.len());
    const first = ctx.stack.pop().?;
    const second = ctx.stack.pop().?;

    try testing.expect(first == .expr);
    try testing.expect(second == .expr);
    try testing.expect(first.expr != second.expr);

    // Clean up expressions since we're using testing.allocator, not an arena
    first.expr.deinit(allocator);
    allocator.destroy(first.expr);
    second.expr.deinit(allocator);
    allocator.destroy(second.expr);
}

test "stack simulation pop except clears exception placeholders pre311" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var consts: [0]pyc.Object = .{};
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(3, 10);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    const ret = try ast.makeName(a, "ret", .load);
    const exc1 = try ast.makeName(a, "__exception__", .load);
    const exc2 = try ast.makeName(a, "__exception__", .load);
    const exc3 = try ast.makeName(a, "__exception__", .load);

    try ctx.stack.push(.{ .expr = ret });
    try ctx.stack.push(.{ .expr = exc1 });
    try ctx.stack.push(.{ .expr = exc2 });
    try ctx.stack.push(.{ .expr = exc3 });

    const inst = Instruction{
        .opcode = .POP_EXCEPT,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 1), ctx.stack.len());
    const val = ctx.stack.peek().?;
    try testing.expect(val == .expr);
    try testing.expect(std.mem.eql(u8, val.expr.name.id, "ret"));

    _ = ctx.stack.pop().?;
}

test "stack simulation pop except clears exc markers pre311" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var consts: [0]pyc.Object = .{};
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(3, 10);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    const ret = try ast.makeName(a, "ret", .load);

    try ctx.stack.push(.{ .expr = ret });
    try ctx.stack.push(.exc_marker);
    try ctx.stack.push(.exc_marker);
    try ctx.stack.push(.exc_marker);

    const inst = Instruction{
        .opcode = .POP_EXCEPT,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 1), ctx.stack.len());
    const val = ctx.stack.peek().?;
    try testing.expect(val == .expr);
    try testing.expect(std.mem.eql(u8, val.expr.name.id, "ret"));

    _ = ctx.stack.pop().?;
}

test "stack simulation pop except no-op pre37" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var consts: [0]pyc.Object = .{};
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(3, 6);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    const ret = try ast.makeName(a, "ret", .load);

    try ctx.stack.push(.{ .expr = ret });
    try ctx.stack.push(.exc_marker);
    try ctx.stack.push(.exc_marker);
    try ctx.stack.push(.exc_marker);

    const inst = Instruction{
        .opcode = .POP_EXCEPT,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 4), ctx.stack.len());
    try testing.expect(ctx.stack.items.items[0] == .expr);
    try testing.expect(ctx.stack.items.items[1] == .exc_marker);
    try testing.expect(ctx.stack.items.items[2] == .exc_marker);
    try testing.expect(ctx.stack.items.items[3] == .exc_marker);

    while (ctx.stack.len() > 0) {
        _ = ctx.stack.pop().?;
    }
}

test "stack simulation pop except clears exception placeholders 3.11+" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var consts: [0]pyc.Object = .{};
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(3, 12);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    const ret = try ast.makeName(a, "ret", .load);
    const exc1 = try ast.makeName(a, "__exception__", .load);

    try ctx.stack.push(.{ .expr = ret });
    try ctx.stack.push(.{ .expr = exc1 });

    const inst = Instruction{
        .opcode = .POP_EXCEPT,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 1), ctx.stack.len());
    const val = ctx.stack.peek().?;
    try testing.expect(val == .expr);
    try testing.expect(std.mem.eql(u8, val.expr.name.id, "ret"));

    _ = ctx.stack.pop().?;
}

test "stack simulation pop except clears exc markers 3.11+" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var consts: [0]pyc.Object = .{};
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(3, 12);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    const ret = try ast.makeName(a, "ret", .load);

    try ctx.stack.push(.{ .expr = ret });
    try ctx.stack.push(.exc_marker);

    const inst = Instruction{
        .opcode = .POP_EXCEPT,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 1), ctx.stack.len());
    const val = ctx.stack.peek().?;
    try testing.expect(val == .expr);
    try testing.expect(std.mem.eql(u8, val.expr.name.id, "ret"));

    _ = ctx.stack.pop().?;
}

test "stack simulation except prologue preserves exc markers pre311" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var consts: [0]pyc.Object = .{};
    var names: [1][]const u8 = .{"KeyError"};
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
        .names = &names,
    };
    const version = Version.init(3, 10);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try ctx.stack.push(.exc_marker);
    }

    const prologue = [_]Instruction{
        .{ .opcode = .DUP_TOP, .arg = 0, .offset = 0, .size = 2, .cache_entries = 0 },
        .{ .opcode = .LOAD_GLOBAL, .arg = 0, .offset = 2, .size = 2, .cache_entries = 0 },
        .{ .opcode = .JUMP_IF_NOT_EXC_MATCH, .arg = 8, .offset = 4, .size = 2, .cache_entries = 0 },
        .{ .opcode = .POP_TOP, .arg = 0, .offset = 6, .size = 2, .cache_entries = 0 },
        .{ .opcode = .POP_TOP, .arg = 0, .offset = 8, .size = 2, .cache_entries = 0 },
        .{ .opcode = .POP_TOP, .arg = 0, .offset = 10, .size = 2, .cache_entries = 0 },
    };
    for (prologue) |inst| {
        try ctx.simulate(inst);
    }

    try testing.expectEqual(@as(usize, 3), ctx.stack.len());
    try testing.expect(ctx.stack.items.items[0] == .exc_marker);
    try testing.expect(ctx.stack.items.items[1] == .exc_marker);
    try testing.expect(ctx.stack.items.items[2] == .exc_marker);

    _ = ctx.stack.pop().?;
    _ = ctx.stack.pop().?;
    _ = ctx.stack.pop().?;
}

test "stack simulation WITH_EXCEPT_START keeps inputs pre311" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var consts: [0]pyc.Object = .{};
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(3, 9);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    const exit_expr = try ast.makeName(a, "__exit__", .load);
    try ctx.stack.push(.{ .expr = exit_expr });
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try ctx.stack.push(.exc_marker);
    }

    const inst = Instruction{
        .opcode = .WITH_EXCEPT_START,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 8), ctx.stack.len());
    const top = ctx.stack.peek().?;
    try testing.expect(top == .unknown);
    // Ensure the previous item wasn't popped.
    const prev = ctx.stack.items.items[ctx.stack.items.items.len - 2];
    try testing.expect(prev == .exc_marker);

    _ = ctx.stack.pop().?;
    while (ctx.stack.len() > 0) {
        _ = ctx.stack.pop().?;
    }
}

test "stack simulation WITH_CLEANUP py2 pushes exc markers" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var consts: [0]pyc.Object = .{};
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(2, 7);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    try ctx.stack.push(.unknown);
    try ctx.stack.push(.unknown);
    try ctx.stack.push(.unknown);
    try ctx.stack.push(.unknown);

    const inst = Instruction{
        .opcode = .WITH_CLEANUP,
        .arg = 0,
        .offset = 0,
        .size = 1,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 3), ctx.stack.len());
    try testing.expect(ctx.stack.items.items[0] == .exc_marker);
    try testing.expect(ctx.stack.items.items[1] == .exc_marker);
    try testing.expect(ctx.stack.items.items[2] == .exc_marker);
    _ = ctx.stack.pop().?;
    _ = ctx.stack.pop().?;
    _ = ctx.stack.pop().?;
}

test "stack simulation END_FINALLY py2 pops three" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var consts: [0]pyc.Object = .{};
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(2, 7);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    try ctx.stack.push(.unknown);
    try ctx.stack.push(.exc_marker);
    try ctx.stack.push(.exc_marker);
    try ctx.stack.push(.exc_marker);
    try ctx.stack.push(.unknown);

    const inst = Instruction{
        .opcode = .END_FINALLY,
        .arg = 0,
        .offset = 0,
        .size = 1,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 2), ctx.stack.len());
    _ = ctx.stack.pop().?;
    _ = ctx.stack.pop().?;
}

test "stack simulation END_FINALLY pre37 pops exc markers" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var consts: [0]pyc.Object = .{};
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(3, 1);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    try ctx.stack.push(.exc_marker);
    try ctx.stack.push(.exc_marker);
    try ctx.stack.push(.exc_marker);

    const inst = Instruction{
        .opcode = .END_FINALLY,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 0), ctx.stack.len());
}

test "stack simulation END_FINALLY 3.7 pops six" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var consts: [0]pyc.Object = .{};
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(3, 7);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try ctx.stack.push(.unknown);
    }

    const inst = Instruction{
        .opcode = .END_FINALLY,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 0), ctx.stack.len());
}

test "flow CALL_FUNCTION pops py2 keyword pairs" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var consts: [0]pyc.Object = .{};
    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(2, 7);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();
    ctx.flow_mode = true;
    ctx.stack.allow_underflow = true;

    try ctx.stack.push(.unknown); // callable
    try ctx.stack.push(.unknown); // pos arg
    try ctx.stack.push(.unknown); // kw name
    try ctx.stack.push(.unknown); // kw value

    const inst = Instruction{
        .opcode = .CALL_FUNCTION,
        .arg = 0x0101, // 1 positional, 1 keyword
        .offset = 0,
        .size = 1,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 1), ctx.stack.len());
    try testing.expect(ctx.stack.peek().? == .unknown);
    _ = ctx.stack.pop().?;
}

test "stack simulation yield value strict error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var code = pyc.Code{
        .allocator = allocator,
    };
    const version = Version.init(3, 12);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    try ctx.stack.push(.null_marker);

    const inst = Instruction{
        .opcode = .YIELD_VALUE,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };

    try testing.expectError(error.NotAnExpression, ctx.simulate(inst));
}

test "stack pop expr unknown uses placeholder name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stack = Stack.init(allocator, allocator);
    defer stack.deinit();

    try stack.push(.unknown);
    const expr = try stack.popExpr();
    defer {
        expr.deinit(allocator);
        allocator.destroy(expr);
    }

    try testing.expect(expr.* == .name);
    try testing.expectEqualStrings("__unknown__", expr.name.id);
    try testing.expect(expr.name.ctx == .load);
    try testing.expectEqual(@as(usize, 0), stack.items.items.len);
}

test "stack simulation set append grows cap" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var code = pyc.Code{
        .allocator = allocator,
    };
    const version = Version.init(3, 12);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    const e0 = try ast.makeConstant(a, .{ .int = 0 });
    const e1 = try ast.makeConstant(a, .{ .int = 1 });
    const e2 = try ast.makeConstant(a, .{ .int = 2 });

    const elts0 = try a.alloc(*Expr, 1);
    elts0[0] = e0;
    const set_expr = try a.create(Expr);
    set_expr.* = .{ .set = .{ .elts = elts0, .cap = elts0.len } };

    const elts1 = try a.alloc(*Expr, 1);
    elts1[0] = e1;
    try ctx.appendSetElts(set_expr, elts1);

    const elts2 = try a.alloc(*Expr, 1);
    elts2[0] = e2;
    try ctx.appendSetElts(set_expr, elts2);

    try testing.expectEqual(@as(usize, 3), set_expr.set.elts.len);
    try testing.expect(set_expr.set.cap >= set_expr.set.elts.len);

    set_expr.deinit(a);
    a.destroy(set_expr);
}

test "stack simulation composite load const" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const DictEntry = @typeInfo(@FieldType(pyc.Object, "dict")).pointer.child;

    var tuple_items = try allocator.alloc(pyc.Object, 2);
    tuple_items[0] = .{ .int = pyc.Int.fromI64(1) };
    tuple_items[1] = .{ .int = pyc.Int.fromI64(2) };

    var dict_entries = try allocator.alloc(DictEntry, 1);
    dict_entries[0] = .{
        .key = .{ .int = pyc.Int.fromI64(1) },
        .value = .{ .int = pyc.Int.fromI64(2) },
    };

    var consts = [_]pyc.Object{
        .{ .tuple = tuple_items },
        .{ .dict = dict_entries },
    };
    defer {
        for (consts[0..]) |*obj| obj.deinit(allocator);
    }

    var code = pyc.Code{
        .allocator = allocator,
        .consts = &consts,
    };
    const version = Version.init(3, 12);

    var ctx = SimContext.init(allocator, allocator, &code, version);
    defer ctx.deinit();

    const tuple_inst = Instruction{
        .opcode = .LOAD_CONST,
        .arg = 0,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(tuple_inst);
    const tuple_val = ctx.stack.pop().?;
    try testing.expect(tuple_val == .expr);
    try testing.expect(tuple_val.expr.* == .constant);
    switch (tuple_val.expr.constant) {
        .tuple => |items| {
            try testing.expectEqual(@as(usize, 2), items.len);
            try testing.expect(ast.constantEqual(items[0], .{ .int = 1 }));
            try testing.expect(ast.constantEqual(items[1], .{ .int = 2 }));
        },
        else => try testing.expect(false),
    }

    var tuple_writer = codegen.Writer.init(allocator);
    defer tuple_writer.deinit(allocator);
    try tuple_writer.writeExpr(allocator, tuple_val.expr);
    const tuple_output = try tuple_writer.getOutput(allocator);
    defer allocator.free(tuple_output);
    try testing.expectEqualStrings("(1, 2)", tuple_output);

    const dict_inst = Instruction{
        .opcode = .LOAD_CONST,
        .arg = 1,
        .offset = 2,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(dict_inst);
    const dict_val = ctx.stack.pop().?;
    try testing.expect(dict_val == .expr);

    var dict_writer = codegen.Writer.init(allocator);
    defer dict_writer.deinit(allocator);
    try dict_writer.writeExpr(allocator, dict_val.expr);
    const dict_output = try dict_writer.getOutput(allocator);
    defer allocator.free(dict_output);
    try testing.expectEqualStrings("{1: 2}", dict_output);

    // Clean up expressions since we're using testing.allocator, not an arena
    tuple_val.expr.deinit(allocator);
    allocator.destroy(tuple_val.expr);
    dict_val.expr.deinit(allocator);
    allocator.destroy(dict_val.expr);
}

test "stack simulation CALL_FUNCTION_KW error clears moved args" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var code = pyc.Code{
        .allocator = allocator,
    };
    const version = Version.init(3, 9);

    var ctx = SimContext.init(a, a, &code, version);
    defer {
        ctx.deinit();
    }

    const callable = try ast.makeName(a, "f", .load);
    try ctx.stack.push(.{ .expr = callable });

    const pos_expr = try ast.makeConstant(a, .{ .int = 1 });
    try ctx.stack.push(.{ .expr = pos_expr });

    try ctx.stack.push(.unknown);

    const kw_name = try a.dupe(u8, "x");
    const kw_name_expr = try ast.makeConstant(a, .{ .string = kw_name });
    const kw_elts = try a.alloc(*Expr, 1);
    kw_elts[0] = kw_name_expr;
    const kw_names_tuple = try ast.makeTuple(a, kw_elts, .load);
    try ctx.stack.push(.{ .expr = kw_names_tuple });

    const inst = Instruction{
        .opcode = .CALL_FUNCTION_KW,
        .arg = 2,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);
    try testing.expect(ctx.stack.items.items.len == 1);
    const top = ctx.stack.items.items[ctx.stack.items.items.len - 1];
    const is_expr = switch (top) {
        .expr => true,
        else => false,
    };
    try testing.expect(is_expr);
}

test "stack simulation function_obj call preserves args" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var code = pyc.Code{
        .allocator = allocator,
        .name = "f",
    };
    const version = Version.init(3, 11);

    var ctx = SimContext.init(a, a, &code, version);
    defer ctx.deinit();

    const func = try a.create(FunctionValue);
    func.* = .{
        .code = &code,
        .decorators = .{},
    };

    try ctx.stack.push(.null_marker);
    try ctx.stack.push(.{ .function_obj = func });

    const arg_expr = try ast.makeConstant(a, .{ .int = 1 });
    try ctx.stack.push(.{ .expr = arg_expr });

    const inst = Instruction{
        .opcode = .CALL,
        .arg = 1,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try ctx.simulate(inst);

    try testing.expectEqual(@as(usize, 1), ctx.stack.len());
    const top = ctx.stack.pop().?;
    try testing.expect(top == .expr);

    var writer = codegen.Writer.init(allocator);
    defer writer.deinit(allocator);
    try writer.writeExpr(allocator, top.expr);
    const output = try writer.getOutput(allocator);
    defer allocator.free(output);

    try testing.expectEqualStrings("f(1)", output);
}

test "stack value type_alias deinit is shallow" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const name_expr = try ast.makeName(allocator, "T", .load);
    const value_expr = try ast.makeName(allocator, "U", .load);
    const elts = try allocator.alloc(*Expr, 2);
    elts[0] = name_expr;
    elts[1] = value_expr;

    const marker = try allocator.create(Expr);
    marker.* = .{ .tuple = .{ .elts = elts, .ctx = .load } };

    var val: StackValue = .{ .type_alias = marker };
    val.deinit(allocator, allocator);

    name_expr.deinit(allocator);
    allocator.destroy(name_expr);
    value_expr.deinit(allocator);
    allocator.destroy(value_expr);
}
