//! Stack simulation for bytecode analysis.
//!
//! Simulates Python's evaluation stack to reconstruct expressions
//! from bytecode instructions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const codegen = @import("codegen.zig");
const decoder = @import("decoder.zig");
const opcodes = @import("opcodes.zig");
const pyc = @import("pyc.zig");

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
    UnsupportedConstant,
    InvalidConstKeyMap,
};

/// Annotation for a function parameter or return type.
pub const Annotation = struct {
    name: []const u8, // Parameter name or "return" for return type
    value: *Expr, // Annotation expression
};

pub const FunctionValue = struct {
    code: *const pyc.Code,
    decorators: std.ArrayList(*Expr),
    defaults: []const *Expr = &.{},
    kw_defaults: []const ?*Expr = &.{},
    annotations: []const Annotation = &.{},

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
    decorators: std.ArrayList(*Expr),

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
    ifs: std.ArrayList(*Expr),
    is_async: bool,

    fn deinit(self: *PendingComp, allocator: Allocator) void {
        if (self.target) |target| {
            target.deinit(allocator);
            allocator.destroy(target);
        }
        if (self.iter) |iter_expr| {
            iter_expr.deinit(allocator);
            allocator.destroy(iter_expr);
        }
        for (self.ifs.items) |cond| {
            cond.deinit(allocator);
            allocator.destroy(cond);
        }
        self.ifs.deinit(allocator);
    }
};

const CompBuilder = struct {
    kind: CompKind,
    generators: std.ArrayList(PendingComp),
    loop_stack: std.ArrayList(usize),
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

    fn deinit(self: *CompBuilder, allocator: Allocator) void {
        self.generators.deinit(allocator);
        self.loop_stack.deinit(allocator);
        allocator.destroy(self);
    }
};

/// Import module tracker.
pub const ImportModule = struct {
    module: []const u8,
    fromlist: []const []const u8,
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
    /// Unknown/untracked value.
    unknown,

    pub fn deinit(self: StackValue, allocator: Allocator) void {
        switch (self) {
            .expr => |e| {
                e.deinit(allocator);
                allocator.destroy(e);
            },
            .comp_builder => |b| {
                b.deinit(allocator);
            },
            // function_obj and class_obj are consumed by decompiler and ownership transfers
            // to arena or they're cleaned up explicitly by the code that creates them
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

    pub fn popExpr(self: *Stack) !*Expr {
        const val = self.pop() orelse return error.StackUnderflow;
        return switch (val) {
            .expr => |e| e,
            .unknown => {
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .name = .{ .id = "__unknown__", .ctx = .load } };
                return expr;
            },
            else => {
                var tmp = val;
                tmp.deinit(self.allocator);
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
        return self.valuesToExprs(values);
    }

    pub fn valuesToExprs(self: *Stack, values: []StackValue) ![]const *Expr {
        const exprs = try self.allocator.alloc(*Expr, values.len);
        var created: std.ArrayListUnmanaged(*Expr) = .{};
        errdefer {
            for (created.items) |e| {
                e.deinit(self.allocator);
                self.allocator.destroy(e);
            }
            created.deinit(self.allocator);
            for (values) |*val| {
                val.deinit(self.allocator);
            }
            if (values.len > 0) self.allocator.free(values);
            self.allocator.free(exprs);
        }

        for (values, 0..) |v, i| {
            exprs[i] = switch (v) {
                .expr => |e| e,
                .unknown => blk: {
                    const expr = try self.allocator.create(Expr);
                    expr.* = .{ .name = .{ .id = "__unknown__", .ctx = .load } };
                    try created.append(self.allocator, expr);
                    break :blk expr;
                },
                else => return error.NotAnExpression,
            };
        }

        if (values.len > 0) self.allocator.free(values);
        created.deinit(self.allocator);
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
    version: Version,
    /// Code object being simulated.
    code: *const pyc.Code,
    /// Current stack state.
    stack: Stack,
    /// Override for iterator locals (used for genexpr/listcomp code objects).
    iter_override: ?IterOverride = null,
    /// Optional comprehension builder not stored on the stack.
    comp_builder: ?*CompBuilder = null,
    /// Pending keyword argument names from KW_NAMES (3.11+).
    pending_kwnames: ?[]const []const u8 = null,
    /// GET_AWAITABLE was seen, next YIELD_FROM should be await.
    pending_await: bool = false,
    /// Relaxed stack simulation (used by stack-flow analysis).
    lenient: bool = false,

    pub fn init(allocator: Allocator, code: *const pyc.Code, version: Version) SimContext {
        return .{
            .allocator = allocator,
            .version = version,
            .code = code,
            .stack = Stack.init(allocator),
            .iter_override = null,
            .comp_builder = null,
            .lenient = false,
        };
    }

    pub fn deinit(self: *SimContext) void {
        self.stack.deinit();
        if (self.iter_override) |ov| {
            if (ov.expr) |expr| {
                expr.deinit(self.allocator);
                self.allocator.destroy(expr);
            }
        }
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
                expr.* = .{ .set = .{ .elts = elts } };
                return expr;
            },
            .frozenset => |items| {
                const elts = try self.objectsToExprs(items);
                const list_expr = try ast.makeList(self.allocator, elts, .load);
                errdefer {
                    list_expr.deinit(self.allocator);
                    self.allocator.destroy(list_expr);
                }
                const func = try ast.makeName(self.allocator, "frozenset", .load);
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

    fn buildClassValue(self: *SimContext, callee_expr: *Expr, args_vals: []StackValue) !bool {
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
            .decorators = .{},
        };

        func.deinit(self.allocator);
        name_expr.deinit(self.allocator);
        self.allocator.destroy(name_expr);
        callee_expr.deinit(self.allocator);
        self.allocator.destroy(callee_expr);
        self.allocator.free(args_vals);

        try self.stack.push(.{ .class_obj = cls });
        return true;
    }

    fn takeClassName(self: *SimContext, value: StackValue) SimError![]const u8 {
        var owned = value;
        errdefer owned.deinit(self.allocator);

        const expr = switch (owned) {
            .expr => |e| e,
            else => return error.NotAnExpression,
        };

        if (expr.* != .constant or expr.constant != .string) return error.InvalidConstant;
        const name = try self.allocator.dupe(u8, expr.constant.string);
        expr.deinit(self.allocator);
        self.allocator.destroy(expr);
        return name;
    }

    fn takeClassBases(self: *SimContext, value: StackValue) SimError![]const *Expr {
        var owned = value;
        const expr = switch (owned) {
            .expr => |e| e,
            else => {
                owned.deinit(self.allocator);
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
            val.deinit(self.allocator);
        }
        if (values.len > 0) self.allocator.free(values);
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

    fn keywordNamesFromValue(self: *SimContext, value: StackValue) SimError![]const []const u8 {
        var owned = value;
        defer owned.deinit(self.allocator);

        const expr = switch (owned) {
            .expr => |e| e,
            else => return error.InvalidKeywordNames,
        };

        if (expr.* != .tuple) return error.InvalidKeywordNames;
        const elts = expr.tuple.elts;

        const names = try self.allocator.alloc([]const u8, elts.len);
        var count: usize = 0;
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
    }

    fn keywordNameFromValue(self: *SimContext, value: StackValue) SimError![]const u8 {
        var owned = value;
        errdefer owned.deinit(self.allocator);

        const expr = switch (owned) {
            .expr => |e| e,
            else => return error.InvalidKeywordNames,
        };

        if (expr.* != .constant or expr.constant != .string) return error.InvalidKeywordNames;
        const name = try self.allocator.dupe(u8, expr.constant.string);
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
                    empty_set.* = .{ .set = .{ .elts = &.{} } };
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
                set_expr.* = .{ .set = .{ .elts = starred } };
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
                    self.allocator.free(args_vals);
                    try self.stack.push(.{ .function_obj = func });
                    return;
                },
                .class_obj => |cls| {
                    try cls.decorators.append(self.allocator, callee_expr);
                    cleanup_callee = false;
                    cleanup_args = false;
                    self.allocator.free(args_vals);
                    try self.stack.push(.{ .class_obj = cls });
                    return;
                },
                else => {},
            }
        }

        if (keywords.len == 0 and self.isBuildClass(callee_expr)) {
            if (try self.buildClassValue(callee_expr, args_vals)) {
                cleanup_callee = false;
                cleanup_args = false;
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
                .decorators = .{},
            };
            func.deinit(self.allocator);
            if (args_vals.len > 0) self.allocator.free(args_vals);
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

                var iter_expr: *Expr = undefined;
                var cleanup_iter = true;
                errdefer if (cleanup_iter) {
                    iter_expr.deinit(self.allocator);
                    self.allocator.destroy(iter_expr);
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

                const comp_expr = try self.buildComprehensionFromCode(comp, iter_expr);
                cleanup_iter = false;
                self.allocator.free(args_vals);
                try self.stack.push(.{ .expr = comp_expr });
            },
            .expr => |callee_expr| {
                try self.handleCallExpr(callee_expr, args_vals, keywords);
            },
            else => {
                deinitKeywordsOwned(self.allocator, keywords);
                self.deinitStackValues(args_vals);
                var val = callable;
                val.deinit(self.allocator);
                return error.NotAnExpression;
            },
        }
    }

    pub fn cloneStackValue(self: *SimContext, value: StackValue) !StackValue {
        return switch (value) {
            .expr => |e| .{ .expr = try ast.cloneExpr(self.allocator, e) },
            .function_obj => |func| .{ .function_obj = try self.cloneFunctionValue(func) },
            .class_obj => |cls| .{ .class_obj = try self.cloneClassValue(cls) },
            .comp_builder => |builder| .{ .comp_builder = try self.cloneCompBuilder(builder) },
            .comp_obj => |comp| .{ .comp_obj = comp },
            .code_obj => |code| .{ .code_obj = code },
            .import_module => |imp| .{ .import_module = imp },
            .null_marker => .null_marker,
            .saved_local => |name| .{ .saved_local = name },
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

        copy.* = .{
            .code = cls.code,
            .name = if (cls.name.len > 0) try self.allocator.dupe(u8, cls.name) else &.{},
            .bases = bases,
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

    /// Parse annotations tuple from MAKE_FUNCTION.
    /// Annotations are a tuple of (name, annotation, ...) pairs.
    fn parseAnnotations(self: *SimContext, val: StackValue) SimError![]const Annotation {
        switch (val) {
            .expr => |expr| {
                if (expr.* == .tuple) {
                    const elts = expr.tuple.elts;
                    // Pairs: name, annotation, name, annotation...
                    const count = elts.len / 2;
                    if (count == 0) return &.{};

                    const result = try self.allocator.alloc(Annotation, count);
                    errdefer self.allocator.free(result);

                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const name_expr = elts[i * 2];
                        const ann_expr = elts[i * 2 + 1];
                        const name = if (name_expr.* == .constant and name_expr.constant == .string)
                            name_expr.constant.string
                        else
                            "<unknown>";
                        result[i] = .{ .name = name, .value = ann_expr };
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
                v.deinit(self.allocator);
                return &.{};
            },
        }
    }

    /// Parse keyword defaults dict from MAKE_FUNCTION.
    fn parseKwDefaults(self: *SimContext, val: StackValue) SimError![]const ?*Expr {
        // For now, just discard - full implementation needs dict handling
        var v = val;
        v.deinit(self.allocator);
        return &.{};
    }

    /// Parse defaults tuple from MAKE_FUNCTION.
    fn parseDefaults(self: *SimContext, val: StackValue) SimError![]const *Expr {
        switch (val) {
            .expr => |expr| {
                if (expr.* == .tuple) {
                    return expr.tuple.elts;
                }
                expr.deinit(self.allocator);
                self.allocator.destroy(expr);
                return &.{};
            },
            else => {
                var v = val;
                v.deinit(self.allocator);
                return &.{};
            },
        }
    }

    fn cloneCompBuilder(self: *SimContext, builder: *const CompBuilder) !*CompBuilder {
        const copy = try self.allocator.create(CompBuilder);
        errdefer copy.deinit(self.allocator);

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
            try copy.generators.ensureTotalCapacity(self.allocator, builder.generators.items.len);
            for (builder.generators.items) |gen| {
                const iter_expr = gen.iter orelse return error.InvalidComprehension;
                var gen_copy = PendingComp{
                    .target = if (gen.target) |target| try ast.cloneExpr(self.allocator, target) else null,
                    .iter = try ast.cloneExpr(self.allocator, iter_expr),
                    .ifs = .{},
                    .is_async = gen.is_async,
                };
                var appended = false;
                errdefer if (!appended) gen_copy.deinit(self.allocator);

                if (gen.ifs.items.len > 0) {
                    try gen_copy.ifs.ensureTotalCapacity(self.allocator, gen.ifs.items.len);
                    for (gen.ifs.items) |cond| {
                        try gen_copy.ifs.append(self.allocator, try ast.cloneExpr(self.allocator, cond));
                    }
                }

                try copy.generators.append(self.allocator, gen_copy);
                appended = true;
            }
        }

        if (builder.loop_stack.items.len > 0) {
            try copy.loop_stack.ensureTotalCapacity(self.allocator, builder.loop_stack.items.len);
            for (builder.loop_stack.items) |idx| {
                try copy.loop_stack.append(self.allocator, idx);
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

                const builder = try self.allocator.create(CompBuilder);
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
            const missing = depth - @as(u32, @intCast(self.stack.items.items.len));
            const builder = try self.allocator.create(CompBuilder);
            builder.* = CompBuilder.init(kind);
            try self.stack.items.insert(self.allocator, 0, .{ .comp_builder = builder });
            var i: u32 = 1;
            while (i < missing) : (i += 1) {
                try self.stack.items.insert(self.allocator, @intCast(i), .unknown);
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
        errdefer pending.deinit(self.allocator);

        const gen_idx = builder.generators.items.len;
        try builder.loop_stack.append(self.allocator, gen_idx);
        errdefer builder.loop_stack.items.len -= 1;

        try builder.generators.append(self.allocator, pending);
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
        try builder.generators.items[idx].ifs.append(self.allocator, cond);
    }

    fn addCompTargetName(self: *SimContext, name: []const u8) !void {
        const builder = self.findActiveCompBuilder() orelse return;
        if (builder.loop_stack.items.len == 0) return;
        const target = try ast.makeName(self.allocator, name, .store);
        try self.addCompTarget(builder, target);
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
        var nested = SimContext.init(self.allocator, comp.code, self.version);
        defer nested.deinit();

        const builder = try self.allocator.create(CompBuilder);
        builder.* = CompBuilder.init(comp.kind);
        errdefer builder.deinit(self.allocator);

        nested.comp_builder = builder;
        nested.iter_override = .{ .index = 0, .expr = iter_expr };

        var iter = decoder.InstructionIterator.init(comp.code.code, self.version);
        while (iter.next()) |inst| {
            switch (inst.opcode) {
                .RETURN_VALUE, .RETURN_CONST => break,
                else => try nested.simulate(inst),
            }
        }

        if (!builder.seen_append) return error.InvalidComprehension;
        const expr = try nested.buildCompExpr(builder);
        builder.deinit(self.allocator);
        return expr;
    }

    /// Simulate a single instruction.
    pub fn simulate(self: *SimContext, inst: Instruction) SimError!void {
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
            .JUMP_FORWARD,
            .JUMP_BACKWARD,
            .JUMP_BACKWARD_NO_INTERRUPT,
            .JUMP_ABSOLUTE,
            .CONTINUE_LOOP,
            => {
                // No stack effect
            },

            .RETURN_GENERATOR => {
                // Push a placeholder generator value (popped by POP_TOP in genexpr prologue)
                try self.stack.push(.unknown);
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
                    switch (obj) {
                        .code, .code_ref => |code| {
                            try self.stack.push(.{ .code_obj = code });
                        },
                        else => {
                            const expr = try self.objToExpr(obj);
                            try self.stack.push(.{ .expr = expr });
                        },
                    }
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
                    const expr = try ast.makeName(self.allocator, name, .load);
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
                    const expr = try ast.makeName(self.allocator, name, .load);
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
                    const name = self.getName(inst.arg) orelse "<unknown>";
                    try self.addCompTargetName(name);
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .STORE_ANNOTATION => {
                // STORE_ANNOTATION namei - stores annotation, value is on stack
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .STORE_FAST => {
                // Pop the value
                if (self.stack.pop()) |v| {
                    const name = self.getLocal(inst.arg) orelse "<unknown>";
                    try self.addCompTargetName(name);
                    var val = v;
                    val.deinit(self.allocator);
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
                        const target = try ast.makeName(self.allocator, store_name, .store);
                        try self.addCompTarget(builder, target);
                    }
                }

                // Deinit the value after storing
                val.deinit(self.allocator);

                // Load from load_idx and push to stack
                if (self.getLocal(load_idx)) |name| {
                    const expr = try ast.makeName(self.allocator, name, .load);
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
                    val.deinit(self.allocator);
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
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
                const sequence = try self.stack.popExpr();
                const item = try self.stack.popExpr();

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
                expr.* = .{ .set = .{ .elts = elts } };
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
                    const func = try ast.makeName(self.allocator, "tuple", .load);
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
                                names[i] = "<unknown>";
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
                    tos.deinit(self.allocator);
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
                    self.allocator.free(args_vals);
                    try self.stack.push(tos);
                } else {
                    // Two stack orders for function calls with NULL:
                    // 1. LOAD_GLOBAL with push_null: [NULL, callable] → tos=callable, tos1=NULL
                    // 2. LOAD_NAME + PUSH_NULL: [callable, NULL] → tos=NULL, tos1=callable
                    if (tos == .null_marker and tos1 == .expr) {
                        // Case 2: LOAD_NAME + PUSH_NULL order
                        callable = tos1;
                        // tos (null_marker) is discarded
                    } else if (tos1 == .null_marker and tos == .expr) {
                        // Case 1: LOAD_GLOBAL with push_null order
                        callable = tos;
                        // tos1 (null_marker) is discarded
                    } else if (tos == .expr and tos1 != .null_marker) {
                        // Method call - tos is callable, tos1 is self
                        callable = tos;
                        tos1.deinit(self.allocator);
                    } else {
                        // Fallback: try tos as callable
                        callable = tos;
                        tos1.deinit(self.allocator);
                    }

                    // Check if KW_NAMES set up keyword argument names
                    if (self.pending_kwnames) |kwnames| {
                        defer {
                            self.allocator.free(kwnames);
                            self.pending_kwnames = null;
                        }
                        const num_kwargs = kwnames.len;
                        const num_posargs = argc - num_kwargs;

                        // Split args into positional and keyword
                        const posargs = args_vals[0..num_posargs];
                        const kwvalues = args_vals[num_posargs..];

                        // Build keyword arguments
                        const keywords = try self.allocator.alloc(ast.Keyword, num_kwargs);
                        errdefer self.allocator.free(keywords);
                        for (kwnames, kwvalues, 0..) |name, kwval, i| {
                            const value = switch (kwval) {
                                .expr => |e| e,
                                else => return error.NotAnExpression,
                            };
                            keywords[i] = .{
                                .arg = if (std.mem.eql(u8, name, "<unknown>")) null else name,
                                .value = value,
                            };
                        }

                        try self.handleCall(callable, posargs, keywords, iter_expr_from_stack);
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
                defer kwnames_val.deinit(self.allocator);

                var kwnames: []const []const u8 = &.{};
                if (kwnames_val == .expr and kwnames_val.expr.* == .tuple) {
                    const tuple_elts = kwnames_val.expr.tuple.elts;
                    const names = try self.allocator.alloc([]const u8, tuple_elts.len);
                    for (tuple_elts, 0..) |elt, i| {
                        if (elt.* == .constant and elt.constant == .string) {
                            names[i] = elt.constant.string;
                        } else {
                            names[i] = "<unknown>";
                        }
                    }
                    kwnames = names;
                }
                defer if (kwnames.len > 0) self.allocator.free(kwnames);

                const num_kwargs = kwnames.len;
                const num_posargs = argc - num_kwargs;

                // Pop all args (positional + keyword values)
                const all_vals = try self.stack.popN(argc);
                defer self.deinitStackValues(all_vals);

                const posargs = all_vals[0..num_posargs];
                const kwvalues = all_vals[num_posargs..];

                // Pop callable (with optional NULL marker)
                const maybe_null = self.stack.pop() orelse return error.StackUnderflow;
                var callable = maybe_null;
                if (maybe_null == .null_marker) {
                    callable = self.stack.pop() orelse return error.StackUnderflow;
                }

                // Build kwargs
                const keywords = try self.allocator.alloc(ast.Keyword, num_kwargs);
                for (kwnames, kwvalues, 0..) |name, kwval, i| {
                    const value = switch (kwval) {
                        .expr => |e| e,
                        else => return error.NotAnExpression,
                    };
                    keywords[i] = .{
                        .arg = if (std.mem.eql(u8, name, "<unknown>")) null else name,
                        .value = value,
                    };
                }

                try self.handleCall(callable, posargs, keywords, null);
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
                    val.deinit(self.allocator);
                    self.deinitStackValues(args_vals);
                    return error.StackUnderflow;
                };
                // If marker is self (an expr), prepend it to args
                if (marker == .expr) {
                    const expr = marker.expr;
                    const args_with_self = self.allocator.alloc(StackValue, args_vals.len + 1) catch |err| {
                        expr.deinit(self.allocator);
                        self.allocator.destroy(expr);
                        var val = callable;
                        val.deinit(self.allocator);
                        self.deinitStackValues(args_vals);
                        return err;
                    };
                    args_with_self[0] = .{ .expr = expr };
                    @memcpy(args_with_self[1..], args_vals);
                    self.allocator.free(args_vals);
                    args_vals = args_with_self;
                } else if (marker != .null_marker) {
                    var val = marker;
                    val.deinit(self.allocator);
                }
                try self.handleCall(callable, args_vals, &[_]ast.Keyword{}, null);
            },

            .CALL_FUNCTION => {
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
                        val.deinit(self.allocator);
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
                        val.deinit(self.allocator);
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
                        val.deinit(self.allocator);
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
                        val.deinit(self.allocator);
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
                        val.deinit(self.allocator);
                        return error.NotAnExpression;
                    },
                }
            },

            .CALL_FUNCTION_KW => {
                if (self.version.lt(3, 6)) {
                    const num_pos: usize = @intCast(inst.arg & 0xFF);
                    const num_kw: usize = @intCast((inst.arg >> 8) & 0xFF);

                    const kwargs_val = self.stack.pop() orelse return error.StackUnderflow;
                    const kwargs_expr = switch (kwargs_val) {
                        .expr => |expr| expr,
                        else => {
                            var val = kwargs_val;
                            val.deinit(self.allocator);
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
                            val.deinit(self.allocator);
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
                        val.deinit(self.allocator);
                    };

                    if (kw_names.len > args_vals.len) return error.InvalidKeywordNames;

                    const pos_count = args_vals.len - kw_names.len;
                    var args: []*Expr = &.{};
                    if (pos_count > 0) {
                        args = try self.allocator.alloc(*Expr, pos_count);
                    }
                    var args_filled: usize = 0;
                    errdefer {
                        for (args[0..args_filled]) |arg| {
                            arg.deinit(self.allocator);
                            self.allocator.destroy(arg);
                        }
                        if (pos_count > 0) self.allocator.free(args);
                    }

                    for (args_vals[0..pos_count], 0..) |val, idx| {
                        switch (val) {
                            .expr => |expr| {
                                args[idx] = expr;
                                args_filled += 1;
                                args_vals[idx] = .unknown;
                            },
                            else => return error.NotAnExpression,
                        }
                    }

                    var keywords: []ast.Keyword = &.{};
                    if (kw_names.len > 0) {
                        keywords = try self.allocator.alloc(ast.Keyword, kw_names.len);
                    }
                    var kw_filled: usize = 0;
                    errdefer {
                        for (keywords[0..kw_filled]) |kw| {
                            if (kw.arg) |arg| self.allocator.free(arg);
                            kw.value.deinit(self.allocator);
                            self.allocator.destroy(kw.value);
                        }
                        if (kw_names.len > 0) self.allocator.free(keywords);
                    }

                    var kw_names_mut = @constCast(kw_names);
                    for (kw_names, 0..) |name, idx| {
                        const arg_idx = pos_count + idx;
                        const val = args_vals[arg_idx];
                        switch (val) {
                            .expr => |expr| {
                                keywords[idx] = .{ .arg = name, .value = expr };
                                kw_filled += 1;
                                kw_names_mut[idx] = "";
                                args_vals[arg_idx] = .unknown;
                            },
                            else => return error.NotAnExpression,
                        }
                    }

                    for (args_vals) |*val| val.* = .unknown;
                    self.allocator.free(args_vals);
                    args_owned = false;
                    self.allocator.free(kw_names);
                    kw_names_owned = false;

                    switch (callable) {
                        .expr => |callee_expr| {
                            callable_owned = false;
                            errdefer {
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
                            }
                            const expr = try ast.makeCallWithKeywords(self.allocator, callee_expr, args, keywords);
                            errdefer {
                                expr.deinit(self.allocator);
                                self.allocator.destroy(expr);
                            }
                            try self.stack.push(.{ .expr = expr });
                        },
                        else => {
                            deinitKeywordsOwned(self.allocator, keywords);
                            if (pos_count > 0) {
                                for (args) |arg| {
                                    arg.deinit(self.allocator);
                                    self.allocator.destroy(arg);
                                }
                                self.allocator.free(args);
                            }
                            return error.NotAnExpression;
                        },
                    }
                }
            },

            .CALL_FUNCTION_EX => {
                const has_kwargs = (inst.arg & 0x01) != 0;
                var kwargs_expr: ?*Expr = null;
                if (has_kwargs) {
                    const kw_val = self.stack.pop() orelse return error.StackUnderflow;
                    switch (kw_val) {
                        .expr => |expr| kwargs_expr = expr,
                        else => {
                            var val = kw_val;
                            val.deinit(self.allocator);
                            return error.NotAnExpression;
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
                    else => {
                        var val = args_val;
                        val.deinit(self.allocator);
                        return error.NotAnExpression;
                    },
                };

                const callable = self.stack.pop() orelse return error.StackUnderflow;

                const starred_arg = if (args_expr.* == .starred)
                    args_expr
                else blk: {
                    errdefer {
                        args_expr.deinit(self.allocator);
                        self.allocator.destroy(args_expr);
                    }
                    break :blk try ast.makeStarred(self.allocator, args_expr, .load);
                };
                const args = try self.allocator.alloc(*Expr, 1);
                args[0] = starred_arg;

                var keywords: []ast.Keyword = &.{};
                if (kwargs_expr) |expr| {
                    keywords = try self.allocator.alloc(ast.Keyword, 1);
                    keywords[0] = .{ .arg = null, .value = expr };
                    kwargs_expr = null;
                }

                var cleanup_args = true;
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
                        cleanup_args = false;
                        cleanup_keywords = false;
                    },
                    else => {
                        var val = callable;
                        val.deinit(self.allocator);
                        return error.NotAnExpression;
                    },
                }
            },

            .RETURN_VALUE => {
                // Pop return value - typically ends simulation
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                } else {
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
                var annotations: []const Annotation = &.{};

                // Python 3.3+ has qualname on TOS (PEP 3155) until 3.11
                if (self.version.gte(3, 3) and self.version.lt(3, 11)) {
                    if (self.stack.pop()) |qualname| {
                        var val = qualname;
                        val.deinit(self.allocator);
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
                                v.deinit(self.allocator);
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
                                        v.deinit(self.allocator);
                                        def_exprs[idx] = try ast.makeName(self.allocator, "<default>", .load);
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
                                const expr = try buildLambdaExpr(self.allocator, code, self.version);
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
                            v.deinit(self.allocator);
                            const expr = try ast.makeName(self.allocator, "<function>", .load);
                            try self.stack.push(.{ .expr = expr });
                        },
                    }
                    return;
                }

                // Python 3.3+: pop code object
                const code_val = self.stack.pop() orelse return error.StackUnderflow;

                if ((inst.arg & 0x08) != 0) {
                    if (self.stack.pop()) |closure| {
                        var val = closure;
                        val.deinit(self.allocator);
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
                        kw_defaults = try self.parseKwDefaults(kwdefaults);
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
                            const expr = try buildLambdaExpr(self.allocator, code, self.version);
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

                        const expr = try ast.makeName(self.allocator, func_name, .load);
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
                        val.deinit(self.allocator);
                    } else {
                        return error.StackUnderflow;
                    }
                }

                // Pop code object
                const code_val = self.stack.pop() orelse return error.StackUnderflow;

                // Pop closure tuple (already consumed by BUILD_TUPLE which pushed unknown)
                if (self.stack.pop()) |closure| {
                    var val = closure;
                    val.deinit(self.allocator);
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
                                val.deinit(self.allocator);
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
                            const expr = try buildLambdaExpr(self.allocator, code, self.version);
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
                        const expr = try ast.makeName(self.allocator, "<closure>", .load);
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
                    attr_val.deinit(self.allocator);
                    func_val.deinit(self.allocator);
                    return error.NotAnExpression;
                }

                const flag = inst.arg;
                switch (flag) {
                    1 => { // defaults
                        if (attr_val == .expr and attr_val.expr.* == .tuple) {
                            func_val.function_obj.defaults = attr_val.expr.tuple.elts;
                        } else {
                            attr_val.deinit(self.allocator);
                        }
                    },
                    2 => { // kwdefaults
                        // kwdefaults is a dict - need to extract to []?*Expr
                        attr_val.deinit(self.allocator);
                    },
                    4 => { // annotations
                        const func = func_val.function_obj;
                        func.annotations = self.parseAnnotations(attr_val) catch &.{};
                    },
                    8 => { // closure - ignore
                        attr_val.deinit(self.allocator);
                    },
                    16 => { // annotate (Python 3.14+ - PEP 649 deferred annotations)
                        // This sets __annotate__ which is a function, not a dict
                        // For now, ignore as we'd need to run/analyze the code object
                        attr_val.deinit(self.allocator);
                    },
                    else => {
                        attr_val.deinit(self.allocator);
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
                    const expr = try ast.makeName(self.allocator, name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
            },

            .STORE_DEREF => {
                // STORE_DEREF i - stores value to a cell
                if (self.stack.pop()) |v| {
                    const name = self.getDeref(inst.arg) orelse "<unknown>";
                    try self.addCompTargetName(name);
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            // Stack manipulation opcodes
            .DUP_TOP => {
                // DUP_TOP - duplicate top of stack
                const top = self.stack.peek() orelse return error.StackUnderflow;
                try self.stack.push(try self.cloneStackValue(top));
            },

            .DUP_TOP_TWO => {
                const len = self.stack.items.items.len;
                if (len < 2) return error.StackUnderflow;
                try self.stack.items.ensureUnusedCapacity(self.allocator, 2);
                const second = self.stack.items.items[len - 2];
                const top = self.stack.items.items[len - 1];
                try self.stack.push(try self.cloneStackValue(second));
                try self.stack.push(try self.cloneStackValue(top));
            },

            .DUP_TOPX => {
                const count: usize = @intCast(inst.arg);
                if (count == 0) return error.InvalidDupArg;
                if (count > self.stack.items.items.len) return error.StackUnderflow;
                try self.stack.items.ensureUnusedCapacity(self.allocator, count);

                const start = self.stack.items.items.len - count;
                const items = self.stack.items.items;

                var clones = try self.allocator.alloc(StackValue, count);
                defer self.allocator.free(clones);
                var cloned_count: usize = 0;
                errdefer {
                    for (clones[0..cloned_count]) |*val| val.deinit(self.allocator);
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
                if (self.stack.items.items.len < 2) return error.StackUnderflow;
                const len = self.stack.items.items.len;
                const tmp = self.stack.items.items[len - 1];
                self.stack.items.items[len - 1] = self.stack.items.items[len - 2];
                self.stack.items.items[len - 2] = tmp;
            },

            .ROT_THREE => {
                if (self.stack.items.items.len < 3) return error.StackUnderflow;
                const len = self.stack.items.items.len;
                const top = self.stack.items.items[len - 1];
                const second = self.stack.items.items[len - 2];
                const third = self.stack.items.items[len - 3];
                self.stack.items.items[len - 1] = second;
                self.stack.items.items[len - 2] = third;
                self.stack.items.items[len - 3] = top;
            },

            .ROT_FOUR => {
                if (self.stack.items.items.len < 4) return error.StackUnderflow;
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
                if (count > len) return error.StackUnderflow;
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
                if (self.version.gte(2, 0)) {
                    fromlist_val = self.stack.pop() orelse return error.StackUnderflow;
                    if (self.version.gte(2, 5)) {
                        const level = self.stack.pop() orelse return error.StackUnderflow;
                        defer level.deinit(self.allocator);
                    }
                }
                defer if (fromlist_val) |fv| fv.deinit(self.allocator);

                // Extract fromlist tuple if available
                var fromlist: []const []const u8 = &.{};
                if (fromlist_val) |fv| {
                    if (fv == .expr and fv.expr.* == .tuple) {
                        const tuple_elts = fv.expr.tuple.elts;
                        var names: std.ArrayList([]const u8) = .{};
                        for (tuple_elts) |elt| {
                            if (elt.* == .constant and elt.constant == .string) {
                                try names.append(self.allocator, elt.constant.string);
                            }
                        }
                        fromlist = try names.toOwnedSlice(self.allocator);
                    }
                }

                if (self.getName(inst.arg)) |module_name| {
                    try self.stack.push(.{ .import_module = .{
                        .module = module_name,
                        .fromlist = fromlist,
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
                        var new_fromlist: std.ArrayList([]const u8) = .{};
                        try new_fromlist.appendSlice(self.allocator, imp.fromlist);
                        try new_fromlist.append(self.allocator, attr_name);
                        const top_idx = self.stack.items.items.len - 1;
                        self.stack.items.items[top_idx] = .{ .import_module = .{
                            .module = imp.module,
                            .fromlist = try new_fromlist.toOwnedSlice(self.allocator),
                        } };
                        try self.stack.push(.{ .import_module = .{
                            .module = imp.module,
                            .fromlist = &.{attr_name},
                        } });
                    } else {
                        try self.stack.push(.unknown);
                    }
                } else {
                    try self.stack.push(.unknown);
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
                            const attr = try ast.makeAttribute(self.allocator, obj, attr_name, .load);
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
                        val.deinit(self.allocator);
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
                    const attr = try ast.makeAttribute(self.allocator, obj, attr_name, .load);
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
                const attr = try ast.makeAttribute(self.allocator, obj, attr_name, .load);
                // For context managers, these are methods - push [method, self]
                try self.stack.push(.{ .expr = attr });
                try self.stack.push(.{ .expr = obj_copy });
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
                    dict_val.deinit(self.allocator);
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
                defer keys_val.deinit(self.allocator);

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
                    methods_val.deinit(self.allocator);
                    return error.StackUnderflow;
                };
                const name_val = self.stack.pop() orelse {
                    bases_val.deinit(self.allocator);
                    methods_val.deinit(self.allocator);
                    return error.StackUnderflow;
                };

                const class_name = self.takeClassName(name_val) catch |err| {
                    bases_val.deinit(self.allocator);
                    methods_val.deinit(self.allocator);
                    return err;
                };
                const bases = self.takeClassBases(bases_val) catch |err| {
                    self.allocator.free(class_name);
                    methods_val.deinit(self.allocator);
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
                    methods_val.deinit(self.allocator);
                    return error.NotAnExpression;
                }
            },
            .LOAD_BUILD_CLASS => {
                // LOAD_BUILD_CLASS - push __build_class__ builtin onto stack
                // Used to construct classes: __build_class__(func, name, *bases, **keywords)
                const expr = try ast.makeName(self.allocator, "__build_class__", .load);
                try self.stack.push(.{ .expr = expr });
            },

            .LOAD_LOCALS => {
                // LOAD_LOCALS - Python 2.x: push locals() dict onto stack
                // Used at end of class body to return the class namespace
                const func_expr = try ast.makeName(self.allocator, "locals", .load);
                const expr = try ast.makeCall(self.allocator, func_expr, &.{});
                try self.stack.push(.{ .expr = expr });
            },

            .STORE_LOCALS => {
                // STORE_LOCALS - Python 3.0-3.3: store TOS to locals (used in class bodies)
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .LOAD_CLASSDEREF => {
                // LOAD_CLASSDEREF i - load value from cell or free variable for class scoping
                if (self.getDeref(inst.arg)) |name| {
                    const expr = try ast.makeName(self.allocator, name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }
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
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
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
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }
            },

            .RERAISE => {
                // RERAISE depth - re-raise the exception
                // Pops nothing new, exception info already on stack
            },

            .SETUP_FINALLY,
            .SETUP_ASYNC_WITH,
            .BEGIN_FINALLY,
            .CALL_FINALLY,
            .POP_FINALLY,
            .WITH_CLEANUP_START,
            .WITH_CLEANUP_FINISH,
            .POP_EXCEPT,
            => {
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

            // Boolean operations (for short-circuit evaluation)
            .JUMP_IF_TRUE_OR_POP, .JUMP_IF_FALSE_OR_POP => {
                // These leave TOS on stack if condition matches, otherwise pop and jump
                // For simulation, we leave the value on stack (the expr stays)
            },

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
                if (self.findActiveCompBuilder()) |builder| {
                    const final_cond = switch (inst.opcode) {
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
                    val.deinit(self.allocator);
                }
            },

            .YIELD_VALUE => {
                // YIELD_VALUE - yield TOS
                // In await loop (pending_await), just pop/push unknown
                if (self.pending_await) {
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator);
                    }
                    try self.stack.push(.unknown);
                    return;
                }

                const value = self.stack.popExpr() catch {
                    // If we can't get an expr, push unknown and continue
                    _ = self.stack.pop();
                    try self.stack.push(.unknown);
                    return;
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
                const value = try self.stack.popExpr();

                // Check if this is an await (GET_AWAITABLE was seen)
                if (self.pending_await) {
                    self.pending_await = false;
                    // Get the awaitable from stack (GET_AWAITABLE left it there)
                    const awaitable = try self.stack.popExpr();
                    // Discard the None value from LOAD_CONST
                    value.deinit(self.allocator);
                    self.allocator.destroy(value);
                    // Create await expression
                    const expr = try self.allocator.create(Expr);
                    expr.* = .{ .await_expr = .{ .value = awaitable } };
                    try self.stack.push(.{ .expr = expr });
                } else {
                    const expr = try self.allocator.create(Expr);
                    expr.* = .{ .yield_from = .{ .value = value } };
                    try self.stack.push(.{ .expr = expr });
                }
            },

            .SEND => {
                // SEND delta - send value to generator
                // TOS is the value to send, TOS1 is the generator
                // Pop value, push result; generator stays at TOS1
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
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
                                val.deinit(self.allocator);
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
                    awv.deinit(self.allocator);
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
                        val.deinit(self.allocator);
                    }
                    return;
                }
                const item = try self.stack.popExpr();
                const builder = if (self.comp_builder) |b| blk: {
                    if (b.kind != .list) return error.InvalidComprehension;
                    break :blk b;
                } else try self.getBuilderAtDepth(inst.arg, .list);
                if (builder.elt) |old| {
                    old.deinit(self.allocator);
                    self.allocator.destroy(old);
                }
                builder.elt = item;
                builder.seen_append = true;
            },

            .SET_ADD => {
                // SET_ADD i - add TOS to set at STACK[-i]
                // Used in set comprehensions
                // Python: v = POP(); set = PEEK(i); set.add(v)
                if (self.lenient) {
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator);
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
                        val.deinit(self.allocator);
                    }
                    if (self.stack.pop()) |v| {
                        var val = v;
                        val.deinit(self.allocator);
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

                if (items == .expr and items.expr.* == .tuple) {
                    const tuple_expr = items.expr;
                    const tuple_elts = tuple_expr.tuple.elts;
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
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                }
            },

            .DICT_UPDATE => {
                // DICT_UPDATE i - update dict at stack[i] with TOS
                const update_val = self.stack.pop() orelse return error.StackUnderflow;
                errdefer update_val.deinit(self.allocator);

                const idx: usize = @intCast(inst.arg);
                if (idx > self.stack.items.items.len) return error.StackUnderflow;
                const dict_idx = self.stack.items.items.len - idx;

                if (self.stack.items.items[dict_idx] == .expr and
                    self.stack.items.items[dict_idx].expr.* == .dict and
                    update_val == .expr)
                {
                    const dict = &self.stack.items.items[dict_idx].expr.dict;
                    const update_expr = update_val.expr;

                    const old_len = dict.keys.len;
                    const new_len = old_len + 1;

                    const new_keys = try self.allocator.alloc(?*Expr, new_len);
                    const new_values = try self.allocator.alloc(*Expr, new_len);

                    @memcpy(new_keys[0..old_len], dict.keys);
                    @memcpy(new_values[0..old_len], dict.values);

                    new_keys[old_len] = null;
                    new_values[old_len] = update_expr;

                    self.allocator.free(dict.keys);
                    self.allocator.free(dict.values);

                    dict.keys = new_keys;
                    dict.values = new_values;
                } else {
                    update_val.deinit(self.allocator);
                }
            },

            .COPY_DICT_WITHOUT_KEYS => {
                // COPY_DICT_WITHOUT_KEYS - remove keys tuple from a dict copy
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }
                try self.stack.push(.unknown);
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
                try self.stack.push(.unknown);
            },

            .END_ASYNC_FOR => {
                // END_ASYNC_FOR - cleanup after async for loop
                // Pops exception info and async iterator
                _ = self.stack.pop();
                _ = self.stack.pop();
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
                            builder.deinit(self.allocator);
                        }
                    }
                }
            },

            .POP_ITER => {
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
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
                    val.deinit(self.allocator);
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
                // Stack effect 0: pop keys tuple, push values tuple or None (subject stays)
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }
                try self.stack.push(.unknown); // values tuple or None
            },

            .MATCH_CLASS => {
                // Stack effect -2: pop attr_names, class, subject (3); push result (1)
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
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
                    val.deinit(self.allocator);
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
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }
                // Note: file object should already be on stack from earlier LOAD
            },

            .PRINT_NEWLINE_TO => {
                // Pop file object, print newline to it
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }
            },

            .UNPACK_SEQUENCE => {
                // Pop sequence, push N elements as unpack markers
                // Handled at decompile level to detect unpacking pattern
                const seq = self.stack.pop() orelse return error.StackUnderflow;
                _ = seq;

                const count = inst.arg;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    try self.stack.push(.unknown);
                }
            },

            .CALL_INTRINSIC_1 => {
                // Pops 1 arg, pushes result (net: 0)
                // IDs: 3=STOPITERATION_ERROR, 7=TYPEVAR, 11=TYPEALIAS
                _ = self.stack.pop() orelse return error.StackUnderflow;
                try self.stack.push(.unknown);
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
    }
};

fn compKindFromName(name: []const u8) ?CompKind {
    if (std.mem.eql(u8, name, "<listcomp>")) return .list;
    if (std.mem.eql(u8, name, "<setcomp>")) return .set;
    if (std.mem.eql(u8, name, "<dictcomp>")) return .dict;
    if (std.mem.eql(u8, name, "<genexpr>")) return .genexpr;
    return null;
}

pub fn buildLambdaExpr(allocator: Allocator, code: *const pyc.Code, version: Version) SimError!*Expr {
    var ctx = SimContext.init(allocator, code, version);
    defer ctx.deinit();

    var body_expr: ?*Expr = null;

    var iter = decoder.InstructionIterator.init(code.code, version);
    while (iter.next()) |inst| {
        switch (inst.opcode) {
            .RETURN_VALUE => {
                body_expr = try ctx.stack.popExpr();
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
            else => try ctx.simulate(inst),
        }
    }

    const body = body_expr orelse return error.InvalidLambdaBody;
    errdefer {
        body.deinit(allocator);
        allocator.destroy(body);
    }

    const args = try codegen.extractFunctionSignature(allocator, code, &.{}, &.{}, &.{});
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

    var ctx = SimContext.init(allocator, &code, version);
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

    var ctx = SimContext.init(allocator, &code, version);
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

    var code = pyc.Code{
        .allocator = allocator,
    };
    const version = Version.init(3, 9);

    var ctx = SimContext.init(allocator, &code, version);
    defer {
        // Clean up remaining stack items
        while (ctx.stack.pop()) |val| {
            if (val == .expr) {
                val.expr.deinit(allocator);
                allocator.destroy(val.expr);
            }
        }
        ctx.deinit();
    }

    const callable = try ast.makeName(allocator, "f", .load);
    try ctx.stack.push(.{ .expr = callable });

    const pos_expr = try ast.makeConstant(allocator, .{ .int = 1 });
    try ctx.stack.push(.{ .expr = pos_expr });

    try ctx.stack.push(.unknown);

    const kw_name = try allocator.dupe(u8, "x");
    const kw_name_expr = try ast.makeConstant(allocator, .{ .string = kw_name });
    const kw_elts = try allocator.alloc(*Expr, 1);
    kw_elts[0] = kw_name_expr;
    const kw_names_tuple = try ast.makeTuple(allocator, kw_elts, .load);
    try ctx.stack.push(.{ .expr = kw_names_tuple });

    const inst = Instruction{
        .opcode = .CALL_FUNCTION_KW,
        .arg = 2,
        .offset = 0,
        .size = 2,
        .cache_entries = 0,
    };
    try testing.expectError(error.NotAnExpression, ctx.simulate(inst));
}
