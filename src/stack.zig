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
    InvalidStackDepth,
    UnsupportedConstant,
};

pub const FunctionValue = struct {
    code: *const pyc.Code,
    decorators: std.ArrayList(*Expr),

    pub fn deinit(self: *FunctionValue, allocator: Allocator) void {
        for (self.decorators.items) |decorator| {
            decorator.deinit(allocator);
            allocator.destroy(decorator);
        }
        self.decorators.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const ClassValue = struct {
    code: *const pyc.Code,
    name: []const u8,
    bases: []const *Expr,
    decorators: std.ArrayList(*Expr),

    pub fn deinit(self: *ClassValue, allocator: Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        for (self.bases) |base| {
            @constCast(base).deinit(allocator);
            allocator.destroy(base);
        }
        if (self.bases.len > 0) allocator.free(self.bases);
        for (self.decorators.items) |decorator| {
            decorator.deinit(allocator);
            allocator.destroy(decorator);
        }
        self.decorators.deinit(allocator);
        allocator.destroy(self);
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
        for (self.generators.items) |*gen| {
            gen.deinit(allocator);
        }
        self.generators.deinit(allocator);
        self.loop_stack.deinit(allocator);
        if (self.elt) |elt| {
            elt.deinit(allocator);
            allocator.destroy(elt);
        }
        if (self.key) |key| {
            key.deinit(allocator);
            allocator.destroy(key);
        }
        if (self.value) |value| {
            value.deinit(allocator);
            allocator.destroy(value);
        }
        allocator.destroy(self);
    }
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
            .function_obj => |f| f.deinit(allocator),
            .class_obj => |c| c.deinit(allocator),
            .comp_builder => |b| b.deinit(allocator),
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
        errdefer {
            for (values) |*val| {
                val.deinit(self.allocator);
            }
            if (values.len > 0) self.allocator.free(values);
            self.allocator.free(exprs);
        }

        for (values, 0..) |v, i| {
            exprs[i] = switch (v) {
                .expr => |e| e,
                else => return error.NotAnExpression,
            };
        }

        self.allocator.free(values);
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

    pub fn init(allocator: Allocator, code: *const pyc.Code, version: Version) SimContext {
        return .{
            .allocator = allocator,
            .version = version,
            .code = code,
            .stack = Stack.init(allocator),
            .iter_override = null,
            .comp_builder = null,
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

    /// Convert a pyc.Object constant to an AST Constant.
    pub fn objToConstant(self: *SimContext, obj: pyc.Object) !ast.Constant {
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
            else => .none, // TODO: handle tuples, code objects, etc.
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

    fn cloneStackValue(self: *SimContext, value: StackValue) !StackValue {
        return switch (value) {
            .expr => |e| .{ .expr = try ast.cloneExpr(self.allocator, e) },
            .function_obj => |func| .{ .function_obj = try self.cloneFunctionValue(func) },
            .class_obj => |cls| .{ .class_obj = try self.cloneClassValue(cls) },
            .comp_builder => |builder| .{ .comp_builder = try self.cloneCompBuilder(builder) },
            .comp_obj => |comp| .{ .comp_obj = comp },
            .code_obj => |code| .{ .code_obj = code },
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
        const idx = try self.stackIndexFromDepth(depth);
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
            .NOP, .RESUME, .CACHE, .EXTENDED_ARG => {
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
                if (self.getName(if (inst.opcode == .LOAD_GLOBAL) inst.arg >> 1 else inst.arg)) |name| {
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

            .STORE_FAST_LOAD_FAST => {
                // STORE_FAST_LOAD_FAST - store TOS into local and then push it back
                // arg packs store and load indices in 4-bit nibbles (hi, lo)
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }

                const store_idx = (inst.arg >> 4) & 0xF;
                const load_idx = inst.arg & 0xF;

                if (self.getLocal(load_idx)) |name| {
                    const expr = try ast.makeName(self.allocator, name, .load);
                    try self.stack.push(.{ .expr = expr });
                } else {
                    try self.stack.push(.unknown);
                }

                if (self.getLocal(store_idx)) |store_name| {
                    if (self.findActiveCompBuilder()) |builder| {
                        const target = try ast.makeName(self.allocator, store_name, .store);
                        try self.addCompTarget(builder, target);
                    }
                }
            },

            .BINARY_OP => {
                // Pop two operands, create BinOp expression
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

                const op = binOpFromArg(inst.arg);
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
                const args_vals = try self.stack.popN(argc);
                var cleanup_args = true;
                defer {
                    if (cleanup_args) {
                        for (args_vals) |*val| {
                            val.deinit(self.allocator);
                        }
                        self.allocator.free(args_vals);
                    }
                }

                // Check for NULL marker (PUSH_NULL before function)
                const maybe_null = self.stack.pop() orelse return error.StackUnderflow;
                var callable = maybe_null;
                var iter_expr_from_stack: ?*Expr = null;
                if (maybe_null == .null_marker) {
                    callable = self.stack.pop() orelse return error.StackUnderflow;
                } else if (argc == 0 and maybe_null == .expr) {
                    if (self.stack.peek()) |peek| {
                        if (peek == .comp_obj) {
                            iter_expr_from_stack = maybe_null.expr;
                            callable = self.stack.pop().?;
                        }
                    }
                }

                switch (callable) {
                    .comp_obj => |comp| {
                        var iter_expr: *Expr = undefined;
                        if (iter_expr_from_stack) |iter_expr_value| {
                            if (args_vals.len != 0) {
                                iter_expr_value.deinit(self.allocator);
                                self.allocator.destroy(iter_expr_value);
                                return error.InvalidComprehension;
                            }
                            iter_expr = iter_expr_value;
                            cleanup_args = false;
                            self.allocator.free(args_vals);
                        } else {
                            if (args_vals.len != 1) return error.InvalidComprehension;
                            switch (args_vals[0]) {
                                .expr => |expr| {
                                    iter_expr = expr;
                                    cleanup_args = false;
                                    self.allocator.free(args_vals);
                                },
                                else => return error.NotAnExpression,
                            }
                        }

                        const comp_expr = try self.buildComprehensionFromCode(comp, iter_expr);
                        try self.stack.push(.{ .expr = comp_expr });
                        return;
                    },
                    .expr => |callee_expr| {
                        var cleanup_callee = true;
                        errdefer if (cleanup_callee) {
                            callee_expr.deinit(self.allocator);
                            self.allocator.destroy(callee_expr);
                        };

                        if (args_vals.len == 1) {
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

                        if (self.isBuildClass(callee_expr)) {
                            if (try self.buildClassValue(callee_expr, args_vals)) {
                                cleanup_args = false;
                                cleanup_callee = false;
                                return;
                            }
                        }

                        const args = self.stack.valuesToExprs(args_vals) catch |err| {
                            cleanup_args = false;
                            return err;
                        };
                        cleanup_args = false;
                        errdefer {
                            for (args) |arg| {
                                arg.deinit(self.allocator);
                                self.allocator.destroy(arg);
                            }
                            if (args.len > 0) self.allocator.free(args);
                        }
                        const expr = try ast.makeCall(self.allocator, callee_expr, args);
                        cleanup_callee = false;
                        try self.stack.push(.{ .expr = expr });
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
                // In Python 3.12+, the code object is on top of stack.
                // The function name comes from the code object's co_qualname.
                //
                // Stack: code_obj -> function
                //
                // For now, we create a placeholder Name expression for the function.
                // Full function decompilation requires recursively processing the code object.
                const code_val = self.stack.pop() orelse return error.StackUnderflow;

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

            // Import opcodes
            .IMPORT_NAME => {
                // IMPORT_NAME namei - imports module names[namei]
                // Stack: fromlist, level -> module
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
                const obj = try self.stack.popExpr();
                errdefer {
                    obj.deinit(self.allocator);
                    self.allocator.destroy(obj);
                }
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
                errdefer self.allocator.destroy(expr);

                if (count == 0) {
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

            // Slice operations
            .BUILD_SLICE => {
                // BUILD_SLICE argc - build slice from argc elements
                // argc=2: TOS1:TOS, argc=3: TOS2:TOS1:TOS
                const argc = inst.arg;
                var step: ?*Expr = null;
                if (argc == 3) {
                    step = try self.stack.popExpr();
                }
                errdefer if (step) |s| {
                    s.deinit(self.allocator);
                    self.allocator.destroy(s);
                };
                const stop = try self.stack.popExpr();
                errdefer {
                    stop.deinit(self.allocator);
                    self.allocator.destroy(stop);
                }
                const start = try self.stack.popExpr();
                errdefer {
                    start.deinit(self.allocator);
                    self.allocator.destroy(start);
                }

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
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }
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

            .TO_BOOL => {
                // Preserve the existing expression for decompilation.
            },

            .POP_JUMP_IF_TRUE, .POP_JUMP_IF_FALSE, .POP_JUMP_IF_NONE, .POP_JUMP_IF_NOT_NONE => {
                const cond = try self.stack.popExpr();
                if (self.findActiveCompBuilder()) |builder| {
                    const final_cond = switch (inst.opcode) {
                        .POP_JUMP_IF_FALSE => try ast.makeUnaryOp(self.allocator, .not_, cond),
                        .POP_JUMP_IF_NONE => try self.makeIsNoneCompare(cond, false),
                        .POP_JUMP_IF_NOT_NONE => try self.makeIsNoneCompare(cond, true),
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

            .YIELD_VALUE => {
                // YIELD_VALUE - yield TOS
                const value = try self.stack.popExpr();
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

            .SEND => {
                // SEND delta - send value to generator
                // TOS is the value to send, TOS1 is the generator
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }
                // Generator stays, received value pushed
                try self.stack.push(.unknown);
            },

            // Comprehension opcodes
            .LIST_APPEND => {
                // LIST_APPEND i - append TOS to list at stack[i]
                // Used in list comprehensions
                // Stack: ..., list, ..., item -> ..., list, ...
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
                // SET_ADD i - add TOS to set at stack[i]
                // Used in set comprehensions
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
                // MAP_ADD i - add TOS1:TOS to dict at stack[i]
                // Used in dict comprehensions
                // Stack: ..., dict, ..., key, value -> ..., dict, ...
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

            // Unpacking
            .UNPACK_SEQUENCE => {
                // UNPACK_SEQUENCE count - unpack TOS into count values
                const count = inst.arg;
                if (self.stack.pop()) |v| {
                    var val = v;
                    val.deinit(self.allocator);
                } else {
                    return error.StackUnderflow;
                }
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

    const args = try codegen.extractFunctionSignature(allocator, code);
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
    defer first.deinit(allocator);
    defer second.deinit(allocator);

    try testing.expect(first == .expr);
    try testing.expect(second == .expr);
    try testing.expect(first.expr != second.expr);
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
    defer tuple_val.deinit(allocator);
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
    defer dict_val.deinit(allocator);
    try testing.expect(dict_val == .expr);

    var dict_writer = codegen.Writer.init(allocator);
    defer dict_writer.deinit(allocator);
    try dict_writer.writeExpr(allocator, dict_val.expr);
    const dict_output = try dict_writer.getOutput(allocator);
    defer allocator.free(dict_output);
    try testing.expectEqualStrings("{1: 2}", dict_output);
}
