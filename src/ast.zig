//! Python Abstract Syntax Tree (AST) representation.
//!
//! Represents Python source code as a tree structure for code generation.
//! Designed to match Python's own AST module structure.

const std = @import("std");
const pyc = @import("pyc.zig");
const Allocator = std.mem.Allocator;
const BigInt = pyc.BigInt;

/// Source location information.
pub const Location = struct {
    line: u32 = 0,
    col: u32 = 0,
    end_line: u32 = 0,
    end_col: u32 = 0,

    /// Create a location from line info.
    pub fn fromLine(line: u32) Location {
        return .{ .line = line, .end_line = line };
    }

    /// Merge two locations to span both.
    pub fn merge(self: Location, other: Location) Location {
        const start_line = @min(self.line, other.line);
        const start_col = if (self.line < other.line) self.col else if (other.line < self.line) other.col else @min(self.col, other.col);
        const end_line = @max(self.end_line, other.end_line);
        const end_col = if (self.end_line > other.end_line) self.end_col else if (other.end_line > self.end_line) other.end_col else @max(self.end_col, other.end_col);
        return .{
            .line = start_line,
            .col = start_col,
            .end_line = end_line,
            .end_col = end_col,
        };
    }

    /// Check if location is valid (has non-zero line).
    pub fn isValid(self: Location) bool {
        return self.line > 0;
    }
};

/// A located node wrapper that adds source location to any type.
pub fn Located(comptime T: type) type {
    return struct {
        value: T,
        location: Location = .{},

        const Self = @This();

        pub fn init(value: T, location: Location) Self {
            return .{ .value = value, .location = location };
        }

        pub fn withLocation(value: T, line: u32, col: u32, end_line: u32, end_col: u32) Self {
            return .{
                .value = value,
                .location = .{ .line = line, .col = col, .end_line = end_line, .end_col = end_col },
            };
        }
    };
}

/// Comparison operators.
pub const CmpOp = enum {
    eq, // ==
    not_eq, // !=
    lt, // <
    lte, // <=
    gt, // >
    gte, // >=
    is, // is
    is_not, // is not
    in_, // in
    not_in, // not in

    pub fn symbol(self: CmpOp) []const u8 {
        return switch (self) {
            .eq => "==",
            .not_eq => "!=",
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
            .is => "is",
            .is_not => "is not",
            .in_ => "in",
            .not_in => "not in",
        };
    }
};

/// Binary operators.
pub const BinOp = enum {
    add, // +
    sub, // -
    mult, // *
    div, // /
    mod, // %
    pow, // **
    lshift, // <<
    rshift, // >>
    bitor, // |
    bitxor, // ^
    bitand, // &
    floordiv, // //
    matmult, // @

    pub fn symbol(self: BinOp) []const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .mult => "*",
            .div => "/",
            .mod => "%",
            .pow => "**",
            .lshift => "<<",
            .rshift => ">>",
            .bitor => "|",
            .bitxor => "^",
            .bitand => "&",
            .floordiv => "//",
            .matmult => "@",
        };
    }

    /// Get precedence level for parenthesization.
    pub fn precedence(self: BinOp) u8 {
        return switch (self) {
            .pow => 12,
            .matmult, .mult, .div, .floordiv, .mod => 11,
            .add, .sub => 10,
            .lshift, .rshift => 9,
            .bitand => 8,
            .bitxor => 7,
            .bitor => 6,
        };
    }
};

/// Unary operators.
pub const UnaryOp = enum {
    invert, // ~
    not_, // not
    uadd, // +
    usub, // -

    pub fn symbol(self: UnaryOp) []const u8 {
        return switch (self) {
            .invert => "~",
            .not_ => "not ",
            .uadd => "+",
            .usub => "-",
        };
    }
};

/// Boolean operators.
pub const BoolOp = enum {
    and_,
    or_,

    pub fn symbol(self: BoolOp) []const u8 {
        return switch (self) {
            .and_ => "and",
            .or_ => "or",
        };
    }
};

/// Expression context (load, store, del).
pub const ExprContext = enum {
    load,
    store,
    del,
};

/// Expression node types.
pub const Expr = union(enum) {
    /// Boolean operation: x and y, x or y
    bool_op: struct {
        op: BoolOp,
        values: []const *Expr,
    },

    /// Named expression (walrus operator): x := y
    named_expr: struct {
        target: *Expr,
        value: *Expr,
    },

    /// Binary operation: x + y
    bin_op: struct {
        left: *Expr,
        op: BinOp,
        right: *Expr,
    },

    /// Unary operation: -x, not x
    unary_op: struct {
        op: UnaryOp,
        operand: *Expr,
    },

    /// Lambda expression: lambda x: x + 1
    lambda: struct {
        args: *Arguments,
        body: *Expr,
    },

    /// Conditional expression: a if cond else b
    if_exp: struct {
        condition: *Expr,
        body: *Expr,
        else_body: *Expr,
    },

    /// Dictionary: {k: v, ...}
    dict: struct {
        keys: []const ?*Expr, // null for **spread
        values: []const *Expr,
    },

    /// Set: {a, b, c}
    set: struct {
        elts: []const *Expr,
    },

    /// List comprehension: [x for x in xs]
    list_comp: struct {
        elt: *Expr,
        generators: []const Comprehension,
    },

    /// Set comprehension: {x for x in xs}
    set_comp: struct {
        elt: *Expr,
        generators: []const Comprehension,
    },

    /// Dict comprehension: {k: v for k, v in items}
    dict_comp: struct {
        key: *Expr,
        value: *Expr,
        generators: []const Comprehension,
    },

    /// Generator expression: (x for x in xs)
    generator_exp: struct {
        elt: *Expr,
        generators: []const Comprehension,
    },

    /// Await expression: await x
    await_expr: struct {
        value: *Expr,
    },

    /// Yield expression: yield x
    yield_expr: struct {
        value: ?*Expr,
    },

    /// Yield from: yield from x
    yield_from: struct {
        value: *Expr,
    },

    /// Comparison: x < y < z
    compare: struct {
        left: *Expr,
        ops: []const CmpOp,
        comparators: []const *Expr,
    },

    /// Function call: f(a, b, c=1)
    call: struct {
        func: *Expr,
        args: []const *Expr,
        keywords: []const Keyword,
    },

    /// Formatted value in f-string
    formatted_value: struct {
        value: *Expr,
        conversion: ?u8, // 's', 'r', 'a', or null
        format_spec: ?*Expr,
    },

    /// Joined string (f-string): f"hello {name}"
    joined_str: struct {
        values: []const *Expr,
    },

    /// Constant value: literal numbers, strings, None, True, False
    constant: Constant,

    /// Attribute access: x.attr
    attribute: struct {
        value: *Expr,
        attr: []const u8,
        ctx: ExprContext,
    },

    /// Subscript: x[i]
    subscript: struct {
        value: *Expr,
        slice: *Expr,
        ctx: ExprContext,
    },

    /// Starred expression: *x
    starred: struct {
        value: *Expr,
        ctx: ExprContext,
    },

    /// Variable name: x
    name: struct {
        id: []const u8,
        ctx: ExprContext,
    },

    /// List: [a, b, c]
    list: struct {
        elts: []const *Expr,
        ctx: ExprContext,
    },

    /// Tuple: (a, b, c)
    tuple: struct {
        elts: []const *Expr,
        ctx: ExprContext,
    },

    /// Slice: a:b:c
    slice: struct {
        lower: ?*Expr,
        upper: ?*Expr,
        step: ?*Expr,
    },

    pub fn deinit(self: *Expr, allocator: Allocator) void {
        // Recursively free child nodes
        switch (self.*) {
            .bool_op => |v| {
                deinitExprSlice(allocator, v.values);
            },
            .named_expr => |v| {
                v.target.deinit(allocator);
                allocator.destroy(v.target);
                v.value.deinit(allocator);
                allocator.destroy(v.value);
            },
            .bin_op => |v| {
                v.left.deinit(allocator);
                allocator.destroy(v.left);
                v.right.deinit(allocator);
                allocator.destroy(v.right);
            },
            .unary_op => |v| {
                v.operand.deinit(allocator);
                allocator.destroy(v.operand);
            },
            .lambda => |v| {
                deinitArguments(allocator, v.args);
                v.body.deinit(allocator);
                allocator.destroy(v.body);
            },
            .if_exp => |v| {
                v.condition.deinit(allocator);
                allocator.destroy(v.condition);
                v.body.deinit(allocator);
                allocator.destroy(v.body);
                v.else_body.deinit(allocator);
                allocator.destroy(v.else_body);
            },
            .call => |v| {
                v.func.deinit(allocator);
                allocator.destroy(v.func);
                deinitExprSlice(allocator, v.args);
                deinitKeywords(allocator, v.keywords);
            },
            .compare => |v| {
                v.left.deinit(allocator);
                allocator.destroy(v.left);
                deinitExprSlice(allocator, v.comparators);
                allocator.free(v.ops);
            },
            .list => |v| {
                deinitExprSlice(allocator, v.elts);
            },
            .tuple => |v| {
                deinitExprSlice(allocator, v.elts);
            },
            .set => |v| {
                deinitExprSlice(allocator, v.elts);
            },
            .dict => |v| {
                for (v.keys, v.values) |maybe_key, value| {
                    if (maybe_key) |k| {
                        @constCast(k).deinit(allocator);
                        allocator.destroy(k);
                    }
                    @constCast(value).deinit(allocator);
                    allocator.destroy(value);
                }
                allocator.free(v.keys);
                allocator.free(v.values);
            },
            .list_comp => |v| {
                v.elt.deinit(allocator);
                allocator.destroy(v.elt);
                deinitComprehensions(allocator, v.generators);
            },
            .set_comp => |v| {
                v.elt.deinit(allocator);
                allocator.destroy(v.elt);
                deinitComprehensions(allocator, v.generators);
            },
            .dict_comp => |v| {
                v.key.deinit(allocator);
                allocator.destroy(v.key);
                v.value.deinit(allocator);
                allocator.destroy(v.value);
                deinitComprehensions(allocator, v.generators);
            },
            .generator_exp => |v| {
                v.elt.deinit(allocator);
                allocator.destroy(v.elt);
                deinitComprehensions(allocator, v.generators);
            },
            .await_expr => |v| {
                v.value.deinit(allocator);
                allocator.destroy(v.value);
            },
            .yield_expr => |v| {
                if (v.value) |value| {
                    value.deinit(allocator);
                    allocator.destroy(value);
                }
            },
            .yield_from => |v| {
                v.value.deinit(allocator);
                allocator.destroy(v.value);
            },
            .formatted_value => |v| {
                v.value.deinit(allocator);
                allocator.destroy(v.value);
                if (v.format_spec) |spec| {
                    spec.deinit(allocator);
                    allocator.destroy(spec);
                }
            },
            .joined_str => |v| {
                deinitExprSlice(allocator, v.values);
            },
            .attribute => |v| {
                v.value.deinit(allocator);
                allocator.destroy(v.value);
            },
            .subscript => |v| {
                v.value.deinit(allocator);
                allocator.destroy(v.value);
                v.slice.deinit(allocator);
                allocator.destroy(v.slice);
            },
            .slice => |v| {
                if (v.lower) |lower| {
                    lower.deinit(allocator);
                    allocator.destroy(lower);
                }
                if (v.upper) |upper| {
                    upper.deinit(allocator);
                    allocator.destroy(upper);
                }
                if (v.step) |step| {
                    step.deinit(allocator);
                    allocator.destroy(step);
                }
            },
            .starred => |v| {
                v.value.deinit(allocator);
                allocator.destroy(v.value);
            },
            .constant => |c| c.deinit(allocator),
            .name => {}, // String owned elsewhere
        }
    }
};

/// A constant value.
pub const Constant = union(enum) {
    none,
    true_,
    false_,
    ellipsis,
    int: i64,
    big_int: BigInt,
    float: f64,
    complex: struct { real: f64, imag: f64 },
    string: []const u8,
    bytes: []const u8,

    pub fn deinit(self: Constant, allocator: Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            .bytes => |b| allocator.free(b),
            .big_int => |b| {
                var tmp = b;
                tmp.deinit(allocator);
            },
            else => {},
        }
    }
};

/// Comprehension clause: for target in iter if cond
pub const Comprehension = struct {
    target: *Expr,
    iter: *Expr,
    ifs: []const *Expr,
    is_async: bool,
};

/// Keyword argument: name=value
pub const Keyword = struct {
    arg: ?[]const u8, // null for **kwargs
    value: *Expr,
};

/// Function arguments definition.
pub const Arguments = struct {
    posonlyargs: []const Arg,
    args: []const Arg,
    vararg: ?Arg,
    kwonlyargs: []const Arg,
    kw_defaults: []const ?*Expr,
    kwarg: ?Arg,
    defaults: []const *Expr,

    pub fn deinit(self: *Arguments, allocator: Allocator) void {
        deinitArguments(allocator, self);
    }
};

/// A single function argument.
pub const Arg = struct {
    arg: []const u8,
    annotation: ?*Expr,
    type_comment: ?[]const u8,
};

fn deinitExprSlice(allocator: Allocator, items: []const *Expr) void {
    for (items) |item| {
        @constCast(item).deinit(allocator);
        allocator.destroy(item);
    }
    if (items.len > 0) allocator.free(items);
}

fn deinitOptionalExprSlice(allocator: Allocator, items: []const ?*Expr) void {
    for (items) |item| {
        if (item) |expr| {
            @constCast(expr).deinit(allocator);
            allocator.destroy(expr);
        }
    }
    if (items.len > 0) allocator.free(items);
}

fn deinitKeywords(allocator: Allocator, keywords: []const Keyword) void {
    for (keywords) |kw| {
        if (kw.arg) |arg| allocator.free(arg);
        kw.value.deinit(allocator);
        allocator.destroy(kw.value);
    }
    if (keywords.len > 0) allocator.free(keywords);
}

fn deinitComprehensions(allocator: Allocator, generators: []const Comprehension) void {
    for (generators) |gen| {
        gen.target.deinit(allocator);
        allocator.destroy(gen.target);
        gen.iter.deinit(allocator);
        allocator.destroy(gen.iter);
        deinitExprSlice(allocator, gen.ifs);
    }
    if (generators.len > 0) allocator.free(generators);
}

fn deinitStmtSlice(allocator: Allocator, items: []const *Stmt) void {
    for (items) |stmt| {
        @constCast(stmt).deinit(allocator);
        allocator.destroy(stmt);
    }
    if (items.len > 0) allocator.free(items);
}

fn deinitWithItems(allocator: Allocator, items: []const WithItem) void {
    for (items) |item| {
        item.context_expr.deinit(allocator);
        allocator.destroy(item.context_expr);
        if (item.optional_vars) |vars| {
            vars.deinit(allocator);
            allocator.destroy(vars);
        }
    }
    if (items.len > 0) allocator.free(items);
}

fn deinitAliasSlice(allocator: Allocator, items: []const Alias) void {
    if (items.len > 0) allocator.free(items);
}

fn deinitNameSlice(allocator: Allocator, items: []const []const u8) void {
    if (items.len > 0) allocator.free(items);
}

fn deinitExceptHandlers(allocator: Allocator, handlers: []const ExceptHandler) void {
    for (handlers) |handler| {
        if (handler.type) |exc_type| {
            exc_type.deinit(allocator);
            allocator.destroy(exc_type);
        }
        deinitStmtSlice(allocator, handler.body);
    }
    if (handlers.len > 0) allocator.free(handlers);
}

fn deinitMatchCases(allocator: Allocator, cases: []const MatchCase) void {
    for (cases) |case| {
        case.pattern.deinit(allocator);
        allocator.destroy(case.pattern);
        if (case.guard) |guard| {
            guard.deinit(allocator);
            allocator.destroy(guard);
        }
        deinitStmtSlice(allocator, case.body);
    }
    if (cases.len > 0) allocator.free(cases);
}

fn deinitPatternSlice(allocator: Allocator, items: []const *Pattern) void {
    for (items) |item| {
        item.deinit(allocator);
        allocator.destroy(item);
    }
    if (items.len > 0) allocator.free(items);
}

fn deinitPatternMapping(allocator: Allocator, keys: []const *Expr, patterns: []const *Pattern) void {
    deinitExprSlice(allocator, keys);
    deinitPatternSlice(allocator, patterns);
}

fn deinitPatternClass(
    allocator: Allocator,
    cls: *Expr,
    patterns: []const *Pattern,
    kwd_attrs: []const []const u8,
    kwd_patterns: []const *Pattern,
) void {
    cls.deinit(allocator);
    allocator.destroy(cls);
    deinitPatternSlice(allocator, patterns);
    if (kwd_attrs.len > 0) allocator.free(kwd_attrs);
    deinitPatternSlice(allocator, kwd_patterns);
}

fn deinitPattern(self: *Pattern, allocator: Allocator) void {
    switch (self.*) {
        .match_value => |expr| {
            expr.deinit(allocator);
            allocator.destroy(expr);
        },
        .match_singleton => |value| value.deinit(allocator),
        .match_sequence => |items| deinitPatternSlice(allocator, items),
        .match_mapping => |v| deinitPatternMapping(allocator, v.keys, v.patterns),
        .match_class => |v| deinitPatternClass(allocator, v.cls, v.patterns, v.kwd_attrs, v.kwd_patterns),
        .match_star => {},
        .match_as => |v| {
            if (v.pattern) |pat| {
                pat.deinit(allocator);
                allocator.destroy(pat);
            }
        },
        .match_or => |items| deinitPatternSlice(allocator, items),
    }
}

fn deinitArguments(allocator: Allocator, args: *Arguments) void {
    for (args.posonlyargs) |arg| {
        if (arg.annotation) |ann| {
            ann.deinit(allocator);
            allocator.destroy(ann);
        }
    }
    if (args.posonlyargs.len > 0) allocator.free(args.posonlyargs);

    for (args.args) |arg| {
        if (arg.annotation) |ann| {
            ann.deinit(allocator);
            allocator.destroy(ann);
        }
    }
    if (args.args.len > 0) allocator.free(args.args);

    if (args.vararg) |arg| {
        if (arg.annotation) |ann| {
            ann.deinit(allocator);
            allocator.destroy(ann);
        }
    }

    for (args.kwonlyargs) |arg| {
        if (arg.annotation) |ann| {
            ann.deinit(allocator);
            allocator.destroy(ann);
        }
    }
    if (args.kwonlyargs.len > 0) allocator.free(args.kwonlyargs);

    deinitOptionalExprSlice(allocator, args.kw_defaults);

    if (args.kwarg) |arg| {
        if (arg.annotation) |ann| {
            ann.deinit(allocator);
            allocator.destroy(ann);
        }
    }

    deinitExprSlice(allocator, args.defaults);
    allocator.destroy(args);
}

const CloneError = Allocator.Error;

pub fn cloneConstant(allocator: Allocator, value: Constant) CloneError!Constant {
    return switch (value) {
        .none => .none,
        .true_ => .true_,
        .false_ => .false_,
        .ellipsis => .ellipsis,
        .int => |v| .{ .int = v },
        .big_int => |v| .{ .big_int = try v.clone(allocator) },
        .float => |v| .{ .float = v },
        .complex => |v| .{ .complex = .{ .real = v.real, .imag = v.imag } },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .bytes => |b| .{ .bytes = try allocator.dupe(u8, b) },
    };
}

fn cloneExprSlice(allocator: Allocator, items: []const *Expr) CloneError![]const *Expr {
    if (items.len == 0) return &.{};
    const out = try allocator.alloc(*Expr, items.len);
    var count: usize = 0;
    errdefer {
        deinitExprSlice(allocator, out[0..count]);
    }

    for (items, 0..) |item, idx| {
        out[idx] = try cloneExpr(allocator, item);
        count += 1;
    }

    return out;
}

fn cloneOptionalExprSlice(allocator: Allocator, items: []const ?*Expr) CloneError![]const ?*Expr {
    if (items.len == 0) return &.{};
    const out = try allocator.alloc(?*Expr, items.len);
    var count: usize = 0;
    errdefer {
        deinitOptionalExprSlice(allocator, out[0..count]);
    }

    for (items, 0..) |item, idx| {
        out[idx] = if (item) |expr| try cloneExpr(allocator, expr) else null;
        count += 1;
    }

    return out;
}

fn cloneArg(allocator: Allocator, arg: Arg) CloneError!Arg {
    return .{
        .arg = arg.arg,
        .annotation = if (arg.annotation) |ann| try cloneExpr(allocator, ann) else null,
        .type_comment = arg.type_comment,
    };
}

fn cloneArgSlice(allocator: Allocator, args: []const Arg) CloneError![]const Arg {
    if (args.len == 0) return &.{};
    const out = try allocator.alloc(Arg, args.len);
    var count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (out[i].annotation) |ann| {
                ann.deinit(allocator);
                allocator.destroy(ann);
            }
        }
        allocator.free(out);
    }

    for (args, 0..) |arg, idx| {
        out[idx] = try cloneArg(allocator, arg);
        count += 1;
    }

    return out;
}

fn cloneKeywords(allocator: Allocator, keywords: []const Keyword) CloneError![]const Keyword {
    if (keywords.len == 0) return &.{};
    const out = try allocator.alloc(Keyword, keywords.len);
    var count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (out[i].arg) |arg| allocator.free(arg);
            out[i].value.deinit(allocator);
            allocator.destroy(out[i].value);
        }
        allocator.free(out);
    }

    for (keywords, 0..) |kw, idx| {
        out[idx] = .{
            .arg = if (kw.arg) |arg| try allocator.dupe(u8, arg) else null,
            .value = try cloneExpr(allocator, kw.value),
        };
        count += 1;
    }

    return out;
}

fn cloneComprehensions(allocator: Allocator, generators: []const Comprehension) CloneError![]const Comprehension {
    if (generators.len == 0) return &.{};
    const out = try allocator.alloc(Comprehension, generators.len);
    var count: usize = 0;
    errdefer {
        deinitComprehensions(allocator, out[0..count]);
    }

    for (generators, 0..) |gen, idx| {
        out[idx] = .{
            .target = try cloneExpr(allocator, gen.target),
            .iter = try cloneExpr(allocator, gen.iter),
            .ifs = try cloneExprSlice(allocator, gen.ifs),
            .is_async = gen.is_async,
        };
        count += 1;
    }

    return out;
}

fn cloneArguments(allocator: Allocator, args: *const Arguments) CloneError!*Arguments {
    const out = try allocator.create(Arguments);
    out.* = .{
        .posonlyargs = &.{},
        .args = &.{},
        .vararg = null,
        .kwonlyargs = &.{},
        .kw_defaults = &.{},
        .kwarg = null,
        .defaults = &.{},
    };
    errdefer deinitArguments(allocator, out);

    out.posonlyargs = try cloneArgSlice(allocator, args.posonlyargs);
    out.args = try cloneArgSlice(allocator, args.args);
    if (args.vararg) |va| out.vararg = try cloneArg(allocator, va);
    out.kwonlyargs = try cloneArgSlice(allocator, args.kwonlyargs);
    out.kw_defaults = try cloneOptionalExprSlice(allocator, args.kw_defaults);
    if (args.kwarg) |ka| out.kwarg = try cloneArg(allocator, ka);
    out.defaults = try cloneExprSlice(allocator, args.defaults);

    return out;
}

pub fn cloneExpr(allocator: Allocator, expr: *const Expr) CloneError!*Expr {
    const out = try allocator.create(Expr);
    errdefer allocator.destroy(out);

    out.* = switch (expr.*) {
        .bool_op => |v| .{ .bool_op = .{
            .op = v.op,
            .values = try cloneExprSlice(allocator, v.values),
        } },
        .named_expr => |v| blk: {
            const target = try cloneExpr(allocator, v.target);
            errdefer {
                target.deinit(allocator);
                allocator.destroy(target);
            }
            const value = try cloneExpr(allocator, v.value);
            break :blk .{ .named_expr = .{
                .target = target,
                .value = value,
            } };
        },
        .bin_op => |v| blk: {
            const left = try cloneExpr(allocator, v.left);
            errdefer {
                left.deinit(allocator);
                allocator.destroy(left);
            }
            const right = try cloneExpr(allocator, v.right);
            break :blk .{ .bin_op = .{
                .left = left,
                .op = v.op,
                .right = right,
            } };
        },
        .unary_op => |v| blk: {
            const operand = try cloneExpr(allocator, v.operand);
            break :blk .{ .unary_op = .{ .op = v.op, .operand = operand } };
        },
        .lambda => |v| blk: {
            const args = try cloneArguments(allocator, v.args);
            errdefer deinitArguments(allocator, args);
            const body = try cloneExpr(allocator, v.body);
            break :blk .{ .lambda = .{
                .args = args,
                .body = body,
            } };
        },
        .if_exp => |v| blk: {
            const condition = try cloneExpr(allocator, v.condition);
            errdefer {
                condition.deinit(allocator);
                allocator.destroy(condition);
            }
            const body = try cloneExpr(allocator, v.body);
            errdefer {
                body.deinit(allocator);
                allocator.destroy(body);
            }
            const else_body = try cloneExpr(allocator, v.else_body);
            break :blk .{ .if_exp = .{
                .condition = condition,
                .body = body,
                .else_body = else_body,
            } };
        },
        .dict => |v| blk: {
            const keys = try cloneOptionalExprSlice(allocator, v.keys);
            errdefer deinitOptionalExprSlice(allocator, keys);
            const values = try cloneExprSlice(allocator, v.values);
            break :blk .{ .dict = .{ .keys = keys, .values = values } };
        },
        .set => |v| .{ .set = .{ .elts = try cloneExprSlice(allocator, v.elts) } },
        .list_comp => |v| blk: {
            const elt = try cloneExpr(allocator, v.elt);
            errdefer {
                elt.deinit(allocator);
                allocator.destroy(elt);
            }
            const generators = try cloneComprehensions(allocator, v.generators);
            break :blk .{ .list_comp = .{ .elt = elt, .generators = generators } };
        },
        .set_comp => |v| blk: {
            const elt = try cloneExpr(allocator, v.elt);
            errdefer {
                elt.deinit(allocator);
                allocator.destroy(elt);
            }
            const generators = try cloneComprehensions(allocator, v.generators);
            break :blk .{ .set_comp = .{ .elt = elt, .generators = generators } };
        },
        .dict_comp => |v| blk: {
            const key = try cloneExpr(allocator, v.key);
            errdefer {
                key.deinit(allocator);
                allocator.destroy(key);
            }
            const value = try cloneExpr(allocator, v.value);
            errdefer {
                value.deinit(allocator);
                allocator.destroy(value);
            }
            const generators = try cloneComprehensions(allocator, v.generators);
            break :blk .{ .dict_comp = .{
                .key = key,
                .value = value,
                .generators = generators,
            } };
        },
        .generator_exp => |v| blk: {
            const elt = try cloneExpr(allocator, v.elt);
            errdefer {
                elt.deinit(allocator);
                allocator.destroy(elt);
            }
            const generators = try cloneComprehensions(allocator, v.generators);
            break :blk .{ .generator_exp = .{ .elt = elt, .generators = generators } };
        },
        .await_expr => |v| .{ .await_expr = .{ .value = try cloneExpr(allocator, v.value) } },
        .yield_expr => |v| .{ .yield_expr = .{ .value = if (v.value) |val| try cloneExpr(allocator, val) else null } },
        .yield_from => |v| .{ .yield_from = .{ .value = try cloneExpr(allocator, v.value) } },
        .compare => |v| blk: {
            const left = try cloneExpr(allocator, v.left);
            errdefer {
                left.deinit(allocator);
                allocator.destroy(left);
            }
            const ops = try allocator.dupe(CmpOp, v.ops);
            errdefer allocator.free(ops);
            const comparators = try cloneExprSlice(allocator, v.comparators);
            break :blk .{ .compare = .{
                .left = left,
                .ops = ops,
                .comparators = comparators,
            } };
        },
        .call => |v| blk: {
            const func = try cloneExpr(allocator, v.func);
            errdefer {
                func.deinit(allocator);
                allocator.destroy(func);
            }
            const args = try cloneExprSlice(allocator, v.args);
            errdefer deinitExprSlice(allocator, args);
            const keywords = try cloneKeywords(allocator, v.keywords);
            break :blk .{ .call = .{
                .func = func,
                .args = args,
                .keywords = keywords,
            } };
        },
        .formatted_value => |v| blk: {
            const value = try cloneExpr(allocator, v.value);
            errdefer {
                value.deinit(allocator);
                allocator.destroy(value);
            }
            const format_spec = if (v.format_spec) |spec| try cloneExpr(allocator, spec) else null;
            break :blk .{ .formatted_value = .{
                .value = value,
                .conversion = v.conversion,
                .format_spec = format_spec,
            } };
        },
        .joined_str => |v| .{ .joined_str = .{ .values = try cloneExprSlice(allocator, v.values) } },
        .constant => |v| .{ .constant = try cloneConstant(allocator, v) },
        .attribute => |v| .{ .attribute = .{
            .value = try cloneExpr(allocator, v.value),
            .attr = v.attr,
            .ctx = v.ctx,
        } },
        .subscript => |v| blk: {
            const value = try cloneExpr(allocator, v.value);
            errdefer {
                value.deinit(allocator);
                allocator.destroy(value);
            }
            const slice = try cloneExpr(allocator, v.slice);
            break :blk .{ .subscript = .{
                .value = value,
                .slice = slice,
                .ctx = v.ctx,
            } };
        },
        .starred => |v| .{ .starred = .{
            .value = try cloneExpr(allocator, v.value),
            .ctx = v.ctx,
        } },
        .name => |v| .{ .name = .{ .id = v.id, .ctx = v.ctx } },
        .list => |v| .{ .list = .{
            .elts = try cloneExprSlice(allocator, v.elts),
            .ctx = v.ctx,
        } },
        .tuple => |v| .{ .tuple = .{
            .elts = try cloneExprSlice(allocator, v.elts),
            .ctx = v.ctx,
        } },
        .slice => |v| blk: {
            const lower = if (v.lower) |l| try cloneExpr(allocator, l) else null;
            errdefer if (lower) |lower_expr| {
                lower_expr.deinit(allocator);
                allocator.destroy(lower_expr);
            };
            const upper = if (v.upper) |u| try cloneExpr(allocator, u) else null;
            errdefer if (upper) |upper_expr| {
                upper_expr.deinit(allocator);
                allocator.destroy(upper_expr);
            };
            const step = if (v.step) |s| try cloneExpr(allocator, s) else null;
            break :blk .{ .slice = .{
                .lower = lower,
                .upper = upper,
                .step = step,
            } };
        },
    };

    return out;
}

/// Statement node types.
pub const Stmt = union(enum) {
    /// Function definition
    function_def: struct {
        name: []const u8,
        args: *Arguments,
        body: []const *Stmt,
        decorator_list: []const *Expr,
        returns: ?*Expr,
        type_comment: ?[]const u8,
        is_async: bool,
    },

    /// Class definition
    class_def: struct {
        name: []const u8,
        bases: []const *Expr,
        keywords: []const Keyword,
        body: []const *Stmt,
        decorator_list: []const *Expr,
    },

    /// Return statement
    return_stmt: struct {
        value: ?*Expr,
    },

    /// Delete statement
    delete: struct {
        targets: []const *Expr,
    },

    /// Assignment: x = y
    assign: struct {
        targets: []const *Expr,
        value: *Expr,
        type_comment: ?[]const u8,
    },

    /// Augmented assignment: x += y
    aug_assign: struct {
        target: *Expr,
        op: BinOp,
        value: *Expr,
    },

    /// Annotated assignment: x: int = 1
    ann_assign: struct {
        target: *Expr,
        annotation: *Expr,
        value: ?*Expr,
        simple: bool,
    },

    /// For loop
    for_stmt: struct {
        target: *Expr,
        iter: *Expr,
        body: []const *Stmt,
        else_body: []const *Stmt,
        type_comment: ?[]const u8,
        is_async: bool,
    },

    /// While loop
    while_stmt: struct {
        condition: *Expr,
        body: []const *Stmt,
        else_body: []const *Stmt,
    },

    /// If statement
    if_stmt: struct {
        condition: *Expr,
        body: []const *Stmt,
        else_body: []const *Stmt,
    },

    /// With statement
    with_stmt: struct {
        items: []const WithItem,
        body: []const *Stmt,
        type_comment: ?[]const u8,
        is_async: bool,
    },

    /// Match statement
    match_stmt: struct {
        subject: *Expr,
        cases: []const MatchCase,
    },

    /// Raise statement
    raise_stmt: struct {
        exc: ?*Expr,
        cause: ?*Expr,
    },

    /// Try statement
    try_stmt: struct {
        body: []const *Stmt,
        handlers: []const ExceptHandler,
        else_body: []const *Stmt,
        finalbody: []const *Stmt,
    },

    /// Assert statement
    assert_stmt: struct {
        condition: *Expr,
        msg: ?*Expr,
    },

    /// Import statement
    import_stmt: struct {
        names: []const Alias,
    },

    /// From import statement
    import_from: struct {
        module: ?[]const u8,
        names: []const Alias,
        level: u32,
    },

    /// Global declaration
    global_stmt: struct {
        names: []const []const u8,
    },

    /// Nonlocal declaration
    nonlocal_stmt: struct {
        names: []const []const u8,
    },

    /// Expression statement
    expr_stmt: struct {
        value: *Expr,
    },

    /// Pass statement
    pass,

    /// Break statement
    break_stmt,

    /// Continue statement
    continue_stmt,

    pub fn deinit(self: *Stmt, allocator: Allocator) void {
        switch (self.*) {
            .function_def => |v| {
                if (v.name.len > 0) allocator.free(v.name);
                deinitArguments(allocator, v.args);
                deinitStmtSlice(allocator, v.body);
                deinitExprSlice(allocator, v.decorator_list);
                if (v.returns) |ret| {
                    ret.deinit(allocator);
                    allocator.destroy(ret);
                }
            },
            .class_def => |v| {
                if (v.name.len > 0) allocator.free(v.name);
                deinitExprSlice(allocator, v.bases);
                deinitKeywords(allocator, v.keywords);
                deinitStmtSlice(allocator, v.body);
                deinitExprSlice(allocator, v.decorator_list);
            },
            .return_stmt => |v| {
                if (v.value) |val| {
                    val.deinit(allocator);
                    allocator.destroy(val);
                }
            },
            .delete => |v| {
                deinitExprSlice(allocator, v.targets);
            },
            .assign => |v| {
                deinitExprSlice(allocator, v.targets);
                v.value.deinit(allocator);
                allocator.destroy(v.value);
            },
            .aug_assign => |v| {
                v.target.deinit(allocator);
                allocator.destroy(v.target);
                v.value.deinit(allocator);
                allocator.destroy(v.value);
            },
            .ann_assign => |v| {
                v.target.deinit(allocator);
                allocator.destroy(v.target);
                v.annotation.deinit(allocator);
                allocator.destroy(v.annotation);
                if (v.value) |val| {
                    val.deinit(allocator);
                    allocator.destroy(val);
                }
            },
            .for_stmt => |v| {
                v.target.deinit(allocator);
                allocator.destroy(v.target);
                v.iter.deinit(allocator);
                allocator.destroy(v.iter);
                deinitStmtSlice(allocator, v.body);
                deinitStmtSlice(allocator, v.else_body);
            },
            .while_stmt => |v| {
                v.condition.deinit(allocator);
                allocator.destroy(v.condition);
                deinitStmtSlice(allocator, v.body);
                deinitStmtSlice(allocator, v.else_body);
            },
            .if_stmt => |v| {
                v.condition.deinit(allocator);
                allocator.destroy(v.condition);
                deinitStmtSlice(allocator, v.body);
                deinitStmtSlice(allocator, v.else_body);
            },
            .with_stmt => |v| {
                deinitWithItems(allocator, v.items);
                deinitStmtSlice(allocator, v.body);
            },
            .match_stmt => |v| {
                v.subject.deinit(allocator);
                allocator.destroy(v.subject);
                deinitMatchCases(allocator, v.cases);
            },
            .raise_stmt => |v| {
                if (v.exc) |exc| {
                    exc.deinit(allocator);
                    allocator.destroy(exc);
                }
                if (v.cause) |cause| {
                    cause.deinit(allocator);
                    allocator.destroy(cause);
                }
            },
            .try_stmt => |v| {
                deinitStmtSlice(allocator, v.body);
                deinitExceptHandlers(allocator, v.handlers);
                deinitStmtSlice(allocator, v.else_body);
                deinitStmtSlice(allocator, v.finalbody);
            },
            .assert_stmt => |v| {
                v.condition.deinit(allocator);
                allocator.destroy(v.condition);
                if (v.msg) |msg| {
                    msg.deinit(allocator);
                    allocator.destroy(msg);
                }
            },
            .import_stmt => |v| {
                deinitAliasSlice(allocator, v.names);
            },
            .import_from => |v| {
                deinitAliasSlice(allocator, v.names);
            },
            .global_stmt => |v| {
                deinitNameSlice(allocator, v.names);
            },
            .nonlocal_stmt => |v| {
                deinitNameSlice(allocator, v.names);
            },
            .expr_stmt => |v| {
                v.value.deinit(allocator);
                allocator.destroy(v.value);
            },
            .pass, .break_stmt, .continue_stmt => {},
        }
    }
};

/// With item: expr as target
pub const WithItem = struct {
    context_expr: *Expr,
    optional_vars: ?*Expr,
};

/// Match case
pub const MatchCase = struct {
    pattern: *Pattern,
    guard: ?*Expr,
    body: []const *Stmt,
};

/// Pattern for match statements
pub const Pattern = union(enum) {
    match_value: *Expr,
    match_singleton: Constant,
    match_sequence: []const *Pattern,
    match_mapping: struct {
        keys: []const *Expr,
        patterns: []const *Pattern,
        rest: ?[]const u8,
    },
    match_class: struct {
        cls: *Expr,
        patterns: []const *Pattern,
        kwd_attrs: []const []const u8,
        kwd_patterns: []const *Pattern,
    },
    match_star: ?[]const u8,
    match_as: struct {
        pattern: ?*Pattern,
        name: ?[]const u8,
    },
    match_or: []const *Pattern,

    pub fn deinit(self: *Pattern, allocator: Allocator) void {
        deinitPattern(self, allocator);
    }
};

/// Exception handler
pub const ExceptHandler = struct {
    type: ?*Expr,
    name: ?[]const u8,
    body: []const *Stmt,
};

/// Import alias: name as asname
pub const Alias = struct {
    name: []const u8,
    asname: ?[]const u8,
};

/// Module root
pub const Module = struct {
    body: []const *Stmt,
    type_ignores: []const TypeIgnore,
};

pub const TypeIgnore = struct {
    lineno: u32,
    tag: []const u8,
};

/// Create a name expression.
pub fn makeName(allocator: Allocator, id: []const u8, ctx: ExprContext) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{ .name = .{ .id = id, .ctx = ctx } };
    return expr;
}

/// Create a constant expression.
pub fn makeConstant(allocator: Allocator, value: Constant) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{ .constant = value };
    return expr;
}

/// Create a binary operation expression.
pub fn makeBinOp(allocator: Allocator, left: *Expr, op: BinOp, right: *Expr) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{ .bin_op = .{ .left = left, .op = op, .right = right } };
    return expr;
}

/// Create a function call expression.
pub fn makeCall(allocator: Allocator, func: *Expr, args: []const *Expr) !*Expr {
    return makeCallWithKeywords(allocator, func, args, &.{});
}

/// Create a function call expression with keywords.
pub fn makeCallWithKeywords(
    allocator: Allocator,
    func: *Expr,
    args: []const *Expr,
    keywords: []const Keyword,
) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{ .call = .{ .func = func, .args = args, .keywords = keywords } };
    return expr;
}

/// Create a list expression.
pub fn makeList(allocator: Allocator, elts: []const *Expr, ctx: ExprContext) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{ .list = .{ .elts = elts, .ctx = ctx } };
    return expr;
}

/// Create a tuple expression.
pub fn makeTuple(allocator: Allocator, elts: []const *Expr, ctx: ExprContext) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{ .tuple = .{ .elts = elts, .ctx = ctx } };
    return expr;
}

/// Create an attribute access expression.
pub fn makeAttribute(allocator: Allocator, value: *Expr, attr: []const u8, ctx: ExprContext) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{ .attribute = .{ .value = value, .attr = attr, .ctx = ctx } };
    return expr;
}

/// Create a subscript expression.
pub fn makeSubscript(allocator: Allocator, value: *Expr, slice_expr: *Expr, ctx: ExprContext) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{ .subscript = .{ .value = value, .slice = slice_expr, .ctx = ctx } };
    return expr;
}

/// Create a starred expression.
pub fn makeStarred(allocator: Allocator, value: *Expr, ctx: ExprContext) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{ .starred = .{ .value = value, .ctx = ctx } };
    return expr;
}

/// Create a unary operation expression.
pub fn makeUnaryOp(allocator: Allocator, op: UnaryOp, operand: *Expr) !*Expr {
    const expr = try allocator.create(Expr);
    expr.* = .{ .unary_op = .{ .op = op, .operand = operand } };
    return expr;
}

test "ast create name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const name = try makeName(allocator, "x", .load);
    defer allocator.destroy(name);

    try testing.expectEqualStrings("x", name.name.id);
    try testing.expectEqual(ExprContext.load, name.name.ctx);
}

test "ast create binop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const left = try makeConstant(allocator, .{ .int = 1 });
    const right = try makeConstant(allocator, .{ .int = 2 });
    const binop = try makeBinOp(allocator, left, .add, right);
    defer {
        binop.deinit(allocator);
        allocator.destroy(binop);
    }

    try testing.expectEqual(BinOp.add, binop.bin_op.op);
}
