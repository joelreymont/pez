//! Python Abstract Syntax Tree (AST) representation.
//!
//! Represents Python source code as a tree structure for code generation.
//! Designed to match Python's own AST module structure.

const std = @import("std");
const Allocator = std.mem.Allocator;

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
                for (v.values) |val| {
                    val.deinit(allocator);
                    allocator.destroy(val);
                }
                allocator.free(v.values);
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
            .call => |v| {
                v.func.deinit(allocator);
                allocator.destroy(v.func);
                for (v.args) |arg| {
                    @constCast(arg).deinit(allocator);
                    allocator.destroy(arg);
                }
                allocator.free(v.args);
                allocator.free(v.keywords);
            },
            .list => |v| {
                for (v.elts) |e| {
                    @constCast(e).deinit(allocator);
                    allocator.destroy(e);
                }
                allocator.free(v.elts);
            },
            .tuple => |v| {
                for (v.elts) |e| {
                    @constCast(e).deinit(allocator);
                    allocator.destroy(e);
                }
                allocator.free(v.elts);
            },
            .set => |v| {
                for (v.elts) |e| {
                    @constCast(e).deinit(allocator);
                    allocator.destroy(e);
                }
                allocator.free(v.elts);
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
            .constant => |c| c.deinit(allocator),
            .name => {}, // String owned elsewhere
            else => {},
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
    float: f64,
    complex: struct { real: f64, imag: f64 },
    string: []const u8,
    bytes: []const u8,

    pub fn deinit(self: Constant, allocator: Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            .bytes => |b| allocator.free(b),
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
};

/// A single function argument.
pub const Arg = struct {
    arg: []const u8,
    annotation: ?*Expr,
    type_comment: ?[]const u8,
};

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
    const expr = try allocator.create(Expr);
    expr.* = .{ .call = .{ .func = func, .args = args, .keywords = &.{} } };
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
