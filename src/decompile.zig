//! Main decompilation logic.
//!
//! Combines CFG analysis, control flow detection, and stack simulation
//! to reconstruct Python source code from bytecode.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const cfg_mod = @import("cfg.zig");
const ctrl = @import("ctrl.zig");
const decoder = @import("decoder.zig");
const dom_mod = @import("dom.zig");
const stack_mod = @import("stack.zig");
const pyc = @import("pyc.zig");
const codegen = @import("codegen.zig");

pub const CFG = cfg_mod.CFG;
pub const BasicBlock = cfg_mod.BasicBlock;
pub const Analyzer = ctrl.Analyzer;
pub const SimContext = stack_mod.SimContext;
pub const Version = decoder.Version;
pub const Expr = ast.Expr;
pub const Stmt = ast.Stmt;

/// Decompiler state for a single code object.
pub const Decompiler = struct {
    allocator: Allocator,
    code: *const pyc.Code,
    version: Version,
    cfg: *CFG,
    analyzer: Analyzer,
    dom: dom_mod.DomTree,

    /// Accumulated statements.
    statements: std.ArrayList(*Stmt),

    pub fn init(allocator: Allocator, code: *const pyc.Code, version: Version) !Decompiler {
        // Allocate CFG on heap so pointer stays valid
        const cfg = try allocator.create(CFG);
        errdefer allocator.destroy(cfg);

        cfg.* = if (version.gte(3, 11) and code.exceptiontable.len > 0)
            try cfg_mod.buildCFGWithExceptions(allocator, code.code, code.exceptiontable, version)
        else
            try cfg_mod.buildCFG(allocator, code.code, version);
        errdefer cfg.deinit();

        var analyzer = try Analyzer.init(allocator, cfg);
        errdefer analyzer.deinit();

        var dom = try dom_mod.DomTree.init(allocator, cfg);
        errdefer dom.deinit();

        return .{
            .allocator = allocator,
            .code = code,
            .version = version,
            .cfg = cfg,
            .analyzer = analyzer,
            .dom = dom,
            .statements = .{},
        };
    }

    pub fn deinit(self: *Decompiler) void {
        self.dom.deinit();
        self.analyzer.deinit();
        self.cfg.deinit();
        self.allocator.destroy(self.cfg);
        for (self.statements.items) |stmt| {
            self.allocator.destroy(stmt);
        }
        self.statements.deinit(self.allocator);
    }

    /// Find the last block that's part of an if-elif-else chain.
    fn findIfChainEnd(self: *Decompiler, pattern: ctrl.IfPattern) u32 {
        var max_block = pattern.then_block;

        if (pattern.else_block) |else_id| {
            max_block = @max(max_block, else_id);

            // If this is an elif, recursively find its end
            if (pattern.is_elif) {
                const else_pattern = self.analyzer.detectPattern(else_id);
                if (else_pattern == .if_stmt) {
                    max_block = @max(max_block, self.findIfChainEnd(else_pattern.if_stmt));
                }
            }
        }

        if (pattern.merge_block) |merge| {
            return merge;
        }

        // No merge point - return past the last block in the chain
        return max_block + 1;
    }

    /// Decompile the code object into a list of statements.
    pub fn decompile(self: *Decompiler) ![]const *Stmt {
        if (self.cfg.blocks.len == 0) {
            return self.statements.items;
        }

        // Process blocks in order, using control flow patterns
        var block_idx: u32 = 0;
        while (block_idx < self.cfg.blocks.len) {
            const pattern = self.analyzer.detectPattern(block_idx);

            switch (pattern) {
                .if_stmt => |p| {
                    const stmt = try self.decompileIf(p);
                    if (stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    // Skip all processed blocks
                    block_idx = self.findIfChainEnd(p);
                },
                .while_loop => |p| {
                    const stmt = try self.decompileWhile(p);
                    if (stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    block_idx = p.exit_block;
                },
                .for_loop => |p| {
                    const stmt = try self.decompileFor(p);
                    if (stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    block_idx = p.exit_block;
                },
                .try_stmt => |p| {
                    const result = try self.decompileTry(p);
                    if (result.stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    block_idx = result.next_block;
                },
                .with_stmt => |p| {
                    const result = try self.decompileWith(p);
                    if (result.stmt) |s| {
                        try self.statements.append(self.allocator, s);
                    }
                    block_idx = result.next_block;
                },
                else => {
                    // Process block as sequential statements
                    try self.decompileBlock(block_idx);
                    block_idx += 1;
                },
            }
        }

        return self.statements.items;
    }

    /// Decompile a single basic block into statements.
    fn decompileBlock(self: *Decompiler, block_id: u32) !void {
        if (block_id >= self.cfg.blocks.len) return;
        const block = &self.cfg.blocks[block_id];

        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        for (block.instructions) |inst| {
            // Check for statement-producing instructions
            switch (inst.opcode) {
                .STORE_NAME, .STORE_FAST, .STORE_GLOBAL => {
                    // This is an assignment
                    if (sim.stack.popExpr()) |value| {
                        const name = switch (inst.opcode) {
                            .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg) orelse "<unknown>",
                            .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                            else => "<unknown>",
                        };

                        const target = try ast.makeName(self.allocator, name, .store);
                        const stmt = try self.makeAssign(target, value);
                        try self.statements.append(self.allocator, stmt);
                    }
                },
                .RETURN_VALUE => {
                    if (sim.stack.popExpr()) |value| {
                        const stmt = try self.makeReturn(value);
                        try self.statements.append(self.allocator, stmt);
                    }
                },
                .RETURN_CONST => {
                    if (sim.getConst(inst.arg)) |obj| {
                        const constant = try sim.objToConstant(obj);
                        const value = try ast.makeConstant(self.allocator, constant);
                        const stmt = try self.makeReturn(value);
                        try self.statements.append(self.allocator, stmt);
                    }
                },
                .POP_TOP => {
                    // Expression statement (result discarded)
                    if (sim.stack.popExpr()) |value| {
                        const stmt = try self.makeExprStmt(value);
                        try self.statements.append(self.allocator, stmt);
                    }
                },
                else => {
                    // Simulate the instruction to build up expressions
                    sim.simulate(inst) catch {};
                },
            }
        }
    }

    /// Decompile a range of blocks into a statement list.
    /// Returns statements from start_block up to (but not including) end_block.
    fn decompileBlockRange(self: *Decompiler, start_block: u32, end_block: ?u32) ![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(self.allocator);

        var block_idx = start_block;
        const limit = end_block orelse @as(u32, @intCast(self.cfg.blocks.len));

        while (block_idx < limit) {
            // Process this block's statements
            try self.decompileBlockInto(block_idx, &stmts);
            block_idx += 1;
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    /// Decompile a single block's statements into the provided list.
    fn decompileBlockInto(self: *Decompiler, block_id: u32, stmts: *std.ArrayList(*Stmt)) !void {
        if (block_id >= self.cfg.blocks.len) return;
        const block = &self.cfg.blocks[block_id];

        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .STORE_NAME, .STORE_FAST, .STORE_GLOBAL => {
                    if (sim.stack.popExpr()) |value| {
                        const name = switch (inst.opcode) {
                            .STORE_NAME, .STORE_GLOBAL => sim.getName(inst.arg) orelse "<unknown>",
                            .STORE_FAST => sim.getLocal(inst.arg) orelse "<unknown>",
                            else => "<unknown>",
                        };
                        const target = try ast.makeName(self.allocator, name, .store);
                        const stmt = try self.makeAssign(target, value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .RETURN_VALUE => {
                    if (sim.stack.popExpr()) |value| {
                        const stmt = try self.makeReturn(value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .RETURN_CONST => {
                    if (sim.getConst(inst.arg)) |obj| {
                        const constant = try sim.objToConstant(obj);
                        const value = try ast.makeConstant(self.allocator, constant);
                        const stmt = try self.makeReturn(value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .POP_TOP => {
                    if (sim.stack.popExpr()) |value| {
                        const stmt = try self.makeExprStmt(value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                else => {
                    sim.simulate(inst) catch {};
                },
            }
        }
    }

    /// Decompile an if statement pattern.
    fn decompileIf(self: *Decompiler, pattern: ctrl.IfPattern) !?*Stmt {
        const cond_block = &self.cfg.blocks[pattern.condition_block];

        // Get the condition expression from the last instruction before the jump
        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        // Simulate up to but not including the conditional jump
        for (cond_block.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            sim.simulate(inst) catch {};
        }

        const condition = sim.stack.popExpr() orelse {
            return null;
        };

        // Decompile the then body
        const then_end = pattern.else_block orelse pattern.merge_block;
        const then_body = try self.decompileBlockRange(pattern.then_block, then_end);

        // Decompile the else body
        const else_body = if (pattern.else_block) |else_id| blk: {
            // Check if else is an elif
            if (pattern.is_elif) {
                // The else block is another if statement - recurse
                const else_pattern = self.analyzer.detectPattern(else_id);
                if (else_pattern == .if_stmt) {
                    const elif_stmt = try self.decompileIf(else_pattern.if_stmt);
                    if (elif_stmt) |s| {
                        const body = try self.allocator.alloc(*Stmt, 1);
                        body[0] = s;
                        break :blk body;
                    }
                }
            }
            // Regular else
            break :blk try self.decompileBlockRange(else_id, pattern.merge_block);
        } else &[_]*Stmt{};

        // Create if statement
        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .if_stmt = .{
            .condition = condition,
            .body = then_body,
            .else_body = else_body,
        } };

        return stmt;
    }

    /// Decompile a while loop pattern.
    fn decompileWhile(self: *Decompiler, pattern: ctrl.WhilePattern) !?*Stmt {
        const header = &self.cfg.blocks[pattern.header_block];

        // Get the condition expression
        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        for (header.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            sim.simulate(inst) catch {};
        }

        const condition = sim.stack.popExpr() orelse {
            // Use True as fallback
            return null;
        };

        var visited = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer visited.deinit();

        var skip_first = false;
        const body = try self.decompileLoopBody(
            pattern.body_block,
            pattern.header_block,
            &skip_first,
            &visited,
            null,
        );

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{
            .while_stmt = .{
                .condition = condition,
                .body = body,
                .else_body = &.{},
            },
        };

        return stmt;
    }

    const PatternResult = struct {
        stmt: ?*Stmt,
        next_block: u32,
    };

    fn decompileTry(self: *Decompiler, pattern: ctrl.TryPattern) !PatternResult {
        var handler_blocks = std.ArrayList(u32).init(self.allocator);
        defer handler_blocks.deinit(self.allocator);

        for (pattern.handlers) |handler| {
            try handler_blocks.append(self.allocator, handler.handler_block);
        }
        if (handler_blocks.items.len == 0) {
            return .{ .stmt = null, .next_block = pattern.try_block + 1 };
        }

        std.mem.sort(u32, handler_blocks.items, {}, std.sort.asc(u32));

        var handler_set = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer handler_set.deinit();
        for (handler_blocks.items) |hid| {
            handler_set.set(hid);
        }

        var protected_set = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer protected_set.deinit();
        for (self.cfg.blocks, 0..) |block, i| {
            for (block.successors) |edge| {
                if (edge.edge_type == .exception and handler_set.isSet(edge.target)) {
                    protected_set.set(i);
                    break;
                }
            }
        }

        var post_try_entry: ?u32 = null;
        for (self.cfg.blocks, 0..) |block, i| {
            if (!protected_set.isSet(i)) continue;
            for (block.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (protected_set.isSet(edge.target)) continue;
                if (handler_set.isSet(edge.target)) continue;
                post_try_entry = if (post_try_entry) |prev|
                    @min(prev, edge.target)
                else
                    edge.target;
            }
        }

        var handler_reach = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer handler_reach.deinit();
        for (handler_blocks.items) |hid| {
            var reach = try self.collectReachableNoException(hid, &handler_set);
            defer reach.deinit();
            handler_reach.setUnion(reach);
        }

        var join_block: ?u32 = null;
        if (post_try_entry) |entry| {
            var normal_reach = try self.collectReachableNoException(entry, &handler_set);
            defer normal_reach.deinit();
            var it = normal_reach.iterator(.{});
            while (it.next()) |bit| {
                if (handler_reach.isSet(bit)) {
                    join_block = @intCast(bit);
                    break;
                }
            }
        }

        var has_finally = false;
        for (handler_blocks.items) |hid| {
            if (self.isFinallyHandler(hid)) {
                has_finally = true;
                break;
            }
        }

        var else_start: ?u32 = null;
        if (post_try_entry) |entry| {
            if (!handler_reach.isSet(entry)) {
                if (join_block == null or entry != join_block.?) {
                    else_start = entry;
                }
            }
        }

        var finally_start: ?u32 = null;
        if (has_finally) {
            finally_start = join_block orelse post_try_entry;
        }

        const handler_start = handler_blocks.items[0];
        var try_end: u32 = handler_start;
        if (else_start) |start| {
            if (start < try_end) try_end = start;
        }
        if (finally_start) |start| {
            if (start < try_end) try_end = start;
        }

        const try_body = if (pattern.try_block < try_end)
            try self.decompileStructuredRange(pattern.try_block, try_end)
        else
            &[_]*Stmt{};

        var else_end: u32 = handler_start;
        if (else_start) |start| {
            if (finally_start) |final_start| {
                if (final_start > start and final_start < else_end) else_end = final_start;
            }
            if (join_block) |join| {
                if (join > start and join < else_end) else_end = join;
            }
        }

        const else_body = if (else_start) |start| blk: {
            if (start >= else_end) break :blk &[_]*Stmt{};
            break :blk try self.decompileStructuredRange(start, else_end);
        } else &[_]*Stmt{};

        var final_end: u32 = pattern.exit_block orelse @as(u32, @intCast(self.cfg.blocks.len));
        if (finally_start) |final_start| {
            if (handler_start > final_start and handler_start < final_end) {
                final_end = handler_start;
            }
        }

        const final_body = if (finally_start) |start| blk: {
            if (start >= final_end) break :blk &[_]*Stmt{};
            break :blk try self.decompileStructuredRange(start, final_end);
        } else &[_]*Stmt{};

        var handler_nodes = try self.allocator.alloc(ast.ExceptHandler, handler_blocks.items.len);
        errdefer {
            for (handler_nodes) |*h| {
                if (h.type) |t| {
                    t.deinit(self.allocator);
                    self.allocator.destroy(t);
                }
                if (h.body.len > 0) self.allocator.free(h.body);
            }
            self.allocator.free(handler_nodes);
        }

        for (handler_blocks.items, 0..) |hid, idx| {
            const handler_end = blk: {
                const next_handler = if (idx + 1 < handler_blocks.items.len)
                    handler_blocks.items[idx + 1]
                else
                    (pattern.exit_block orelse @as(u32, @intCast(self.cfg.blocks.len)));
                if (finally_start) |start| {
                    if (start > hid and start < next_handler) break :blk start;
                }
                break :blk next_handler;
            };

            const info = try self.extractHandlerHeader(hid);
            const body = try self.decompileHandlerBody(hid, handler_end, info.skip_first_store);
            handler_nodes[idx] = .{
                .type = info.exc_type,
                .name = info.name,
                .body = body,
            };
        }

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{
            .try_stmt = .{
                .body = try_body,
                .handlers = handler_nodes,
                .else_body = else_body,
                .finalbody = final_body,
            },
        };

        var next_block: u32 = final_end;
        if (next_block < try_end) next_block = try_end;
        if (else_start) |start| {
            if (start > next_block) next_block = start;
        }
        if (pattern.exit_block) |exit| {
            if (exit > next_block) next_block = exit;
        }
        return .{ .stmt = stmt, .next_block = next_block };
    }

    fn decompileWith(self: *Decompiler, pattern: ctrl.WithPattern) !PatternResult {
        const setup = &self.cfg.blocks[pattern.setup_block];
        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        var after_before_with = false;
        var is_async = false;
        var optional_vars: ?*Expr = null;

        for (setup.instructions) |inst| {
            if (inst.opcode == .BEFORE_WITH or inst.opcode == .BEFORE_ASYNC_WITH) {
                after_before_with = true;
                if (inst.opcode == .BEFORE_ASYNC_WITH) {
                    is_async = true;
                }
                continue;
            }
            if (!after_before_with) {
                sim.simulate(inst) catch {};
                continue;
            }

            switch (inst.opcode) {
                .STORE_FAST => {
                    if (sim.getLocal(inst.arg)) |name| {
                        optional_vars = try ast.makeName(self.allocator, name, .store);
                    }
                    break;
                },
                .STORE_NAME, .STORE_GLOBAL => {
                    if (sim.getName(inst.arg)) |name| {
                        optional_vars = try ast.makeName(self.allocator, name, .store);
                    }
                    break;
                },
                else => {},
            }
        }

        const context_expr = sim.stack.popExpr() orelse return .{
            .stmt = null,
            .next_block = pattern.exit_block,
        };

        const item = try self.allocator.alloc(ast.WithItem, 1);
        item[0] = .{
            .context_expr = context_expr,
            .optional_vars = optional_vars,
        };

        const body = try self.decompileStructuredRange(pattern.body_block, pattern.cleanup_block);

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{
            .with_stmt = .{
                .items = item,
                .body = body,
                .type_comment = null,
                .is_async = is_async,
            },
        };

        return .{ .stmt = stmt, .next_block = pattern.exit_block };
    }

    fn decompileStructuredRange(self: *Decompiler, start: u32, end: u32) ![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(self.allocator);

        var block_idx = start;
        const limit = @min(end, @as(u32, @intCast(self.cfg.blocks.len)));

        while (block_idx < limit) {
            const pattern = self.analyzer.detectPattern(block_idx);

            switch (pattern) {
                .if_stmt => |p| {
                    const stmt = try self.decompileIf(p);
                    if (stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx = self.findIfChainEnd(p);
                },
                .while_loop => |p| {
                    const stmt = try self.decompileWhile(p);
                    if (stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx = p.exit_block;
                },
                .for_loop => |p| {
                    const stmt = try self.decompileFor(p);
                    if (stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx = p.exit_block;
                },
                .try_stmt => |p| {
                    const result = try self.decompileTry(p);
                    if (result.stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx = result.next_block;
                },
                .with_stmt => |p| {
                    const result = try self.decompileWith(p);
                    if (result.stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx = result.next_block;
                },
                else => {
                    try self.decompileBlockInto(block_idx, &stmts);
                    block_idx += 1;
                },
            }
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    const HandlerHeader = struct {
        exc_type: ?*Expr,
        name: ?[]const u8,
        skip_first_store: bool,
    };

    fn extractHandlerHeader(self: *Decompiler, handler_block: u32) !HandlerHeader {
        const block = &self.cfg.blocks[handler_block];
        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        var exc_type: ?*Expr = null;
        for (block.instructions) |inst| {
            if (inst.opcode == .CHECK_EXC_MATCH) {
                exc_type = sim.stack.popExpr();
                break;
            }
            sim.simulate(inst) catch {};
        }

        var name: ?[]const u8 = null;
        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .STORE_FAST => {
                    name = sim.getLocal(inst.arg);
                    break;
                },
                .STORE_NAME, .STORE_GLOBAL => {
                    name = sim.getName(inst.arg);
                    break;
                },
                else => {},
            }
        }

        return .{
            .exc_type = exc_type,
            .name = name,
            .skip_first_store = name != null,
        };
    }

    fn decompileHandlerBody(self: *Decompiler, start: u32, end: u32, skip_first_store: bool) ![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(self.allocator);

        if (start >= end or start >= self.cfg.blocks.len) {
            return &[_]*Stmt{};
        }

        var skip_store = skip_first_store;
        try self.processBlockStatements(
            start,
            &self.cfg.blocks[start],
            &stmts,
            &skip_store,
            false,
            null,
        );

        if (start + 1 < end) {
            const rest = try self.decompileStructuredRange(start + 1, end);
            try stmts.appendSlice(self.allocator, rest);
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    fn collectReachableNoException(
        self: *Decompiler,
        start: u32,
        handler_set: *const std.DynamicBitSet,
    ) !std.DynamicBitSet {
        var visited = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        var queue: std.ArrayList(u32) = .{};
        defer queue.deinit(self.allocator);

        if (start >= self.cfg.blocks.len) return visited;
        if (handler_set.isSet(start)) return visited;

        visited.set(start);
        try queue.append(self.allocator, start);

        while (queue.items.len > 0) {
            const node = queue.pop().?;
            const block = &self.cfg.blocks[node];
            for (block.successors) |edge| {
                if (edge.edge_type == .exception) continue;
                if (edge.target >= self.cfg.blocks.len) continue;
                if (handler_set.isSet(edge.target)) continue;
                if (!visited.isSet(edge.target)) {
                    visited.set(edge.target);
                    try queue.append(self.allocator, edge.target);
                }
            }
        }

        return visited;
    }

    fn isFinallyHandler(self: *Decompiler, handler_block: u32) bool {
        const block = &self.cfg.blocks[handler_block];
        for (block.instructions) |inst| {
            if (inst.opcode == .CHECK_EXC_MATCH) return false;
        }
        for (block.instructions) |inst| {
            if (inst.opcode == .RERAISE) return true;
        }
        return false;
    }

    /// Decompile a for loop pattern.
    fn decompileFor(self: *Decompiler, pattern: ctrl.ForPattern) !?*Stmt {
        // Get the iterator expression from the setup block
        // The setup block contains: ... GET_ITER
        // The expression before GET_ITER is the iterator
        const setup = &self.cfg.blocks[pattern.setup_block];

        var iter_sim = SimContext.init(self.allocator, self.code, self.version);
        defer iter_sim.deinit();

        for (setup.instructions) |inst| {
            if (inst.opcode == .GET_ITER) break;
            iter_sim.simulate(inst) catch {};
        }

        const iter_expr = iter_sim.stack.popExpr() orelse
            try ast.makeName(self.allocator, "iter", .load);

        // Get the loop target from the body block's first STORE_FAST
        const body = &self.cfg.blocks[pattern.body_block];
        var target_name: []const u8 = "_";

        for (body.instructions) |inst| {
            if (inst.opcode == .STORE_FAST) {
                if (self.code.varnames.len > inst.arg) {
                    target_name = self.code.varnames[inst.arg];
                }
                break;
            }
        }

        const target = try ast.makeName(self.allocator, target_name, .store);

        // Decompile the body (skip the first STORE_FAST which is the target)
        const body_stmts = try self.decompileForBody(pattern.body_block, pattern.header_block);

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .for_stmt = .{
            .target = target,
            .iter = iter_expr,
            .body = body_stmts,
            .else_body = &.{},
            .type_comment = null,
            .is_async = false,
        } };

        return stmt;
    }

    /// Decompile a for loop body using dominator-based loop membership.
    fn decompileForBody(self: *Decompiler, body_block_id: u32, header_block_id: u32) ![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(self.allocator);

        var visited = try std.DynamicBitSet.initEmpty(self.allocator, self.cfg.blocks.len);
        defer visited.deinit();

        var skip_first_store = true;
        var block_idx = body_block_id;

        while (block_idx < self.cfg.blocks.len) {
            // Use dominator tree to check loop membership
            if (!self.dom.isInLoop(block_idx, header_block_id)) break;

            const block = &self.cfg.blocks[block_idx];

            if (visited.isSet(block_idx)) {
                block_idx += 1;
                continue;
            }
            visited.set(block_idx);

            // Check for nested control flow patterns
            const pattern = self.analyzer.detectPattern(block_idx);

            switch (pattern) {
                .if_stmt => |p| {
                    // Process statements before the condition
                    try self.processPartialBlock(block, &stmts, &skip_first_store);

                    // Handle nested if
                    const if_stmt = try self.decompileLoopIf(p, header_block_id, &visited);
                    if (if_stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }
                    block_idx += 1;
                    continue;
                },
                else => {
                    // Process block statements, stop at loop-back jump
                    const has_back_edge = self.hasLoopBackEdge(block, header_block_id);
                    try self.processBlockStatements(
                        block_idx,
                        block,
                        &stmts,
                        &skip_first_store,
                        has_back_edge,
                        header_block_id,
                    );
                    if (has_back_edge) break;
                    block_idx += 1;
                },
            }
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    /// Check if a block has a back edge to the loop header.
    fn hasLoopBackEdge(self: *Decompiler, block: *const cfg_mod.BasicBlock, header_id: u32) bool {
        _ = self;
        for (block.successors) |edge| {
            if (edge.edge_type == .loop_back and edge.target == header_id) {
                return true;
            }
        }
        return false;
    }

    /// Process statements in a block, stopping before control flow jumps.
    fn processBlockStatements(
        self: *Decompiler,
        block_id: u32,
        block: *const cfg_mod.BasicBlock,
        stmts: *std.ArrayList(*Stmt),
        skip_first_store: *bool,
        stop_at_jump: bool,
        loop_header: ?u32,
    ) !void {
        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        for (block.instructions) |inst| {
            switch (inst.opcode) {
                .STORE_FAST => {
                    if (skip_first_store.*) {
                        skip_first_store.* = false;
                        continue;
                    }
                    if (sim.stack.popExpr()) |value| {
                        const name = sim.getLocal(inst.arg) orelse "<unknown>";
                        const target = try ast.makeName(self.allocator, name, .store);
                        const stmt = try self.makeAssign(target, value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .STORE_NAME, .STORE_GLOBAL => {
                    if (sim.stack.popExpr()) |value| {
                        const name = sim.getName(inst.arg) orelse "<unknown>";
                        const target = try ast.makeName(self.allocator, name, .store);
                        const stmt = try self.makeAssign(target, value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .JUMP_FORWARD, .JUMP_BACKWARD, .JUMP_BACKWARD_NO_INTERRUPT, .JUMP_ABSOLUTE => {
                    if (loop_header) |header_id| {
                        const exit = self.analyzer.detectLoopExit(block_id, &[_]u32{header_id});
                        switch (exit) {
                            .break_stmt => {
                                const stmt = try self.makeBreak();
                                try stmts.append(self.allocator, stmt);
                                return;
                            },
                            .continue_stmt => {
                                const stmt = try self.makeContinue();
                                try stmts.append(self.allocator, stmt);
                                return;
                            },
                            else => {},
                        }
                    }
                    if (stop_at_jump) return;
                },
                .RETURN_VALUE => {
                    if (sim.stack.popExpr()) |value| {
                        const stmt = try self.makeReturn(value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .RETURN_CONST => {
                    if (sim.getConst(inst.arg)) |obj| {
                        const constant = try sim.objToConstant(obj);
                        const value = try ast.makeConstant(self.allocator, constant);
                        const stmt = try self.makeReturn(value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                .POP_TOP => {
                    if (sim.stack.popExpr()) |value| {
                        const stmt = try self.makeExprStmt(value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                else => {
                    sim.simulate(inst) catch {};
                },
            }
        }
    }

    /// Process part of a block (before control flow instruction).
    fn processPartialBlock(self: *Decompiler, block: *const cfg_mod.BasicBlock, stmts: *std.ArrayList(*Stmt), skip_first_store: *bool) !void {
        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        for (block.instructions) |inst| {
            // Stop at control flow instructions
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            if (inst.opcode == .JUMP_BACKWARD or inst.opcode == .JUMP_BACKWARD_NO_INTERRUPT) break;

            switch (inst.opcode) {
                .STORE_FAST => {
                    if (skip_first_store.*) {
                        skip_first_store.* = false;
                        continue;
                    }
                    if (sim.stack.popExpr()) |value| {
                        const name = sim.getLocal(inst.arg) orelse "<unknown>";
                        const target = try ast.makeName(self.allocator, name, .store);
                        const stmt = try self.makeAssign(target, value);
                        try stmts.append(self.allocator, stmt);
                    }
                },
                else => {
                    sim.simulate(inst) catch {};
                },
            }
        }
    }

    /// Decompile an if statement that's inside a loop.
    fn decompileLoopIf(self: *Decompiler, pattern: ctrl.IfPattern, loop_header: u32, visited: *std.DynamicBitSet) !?*Stmt {
        const cond_block = &self.cfg.blocks[pattern.condition_block];

        // Get the condition expression
        var sim = SimContext.init(self.allocator, self.code, self.version);
        defer sim.deinit();

        for (cond_block.instructions) |inst| {
            if (ctrl.Analyzer.isConditionalJump(undefined, inst.opcode)) break;
            sim.simulate(inst) catch {};
        }

        const condition = sim.stack.popExpr() orelse return null;

        const then_in_loop = self.dom.isInLoop(pattern.then_block, loop_header);
        const else_in_loop = if (pattern.else_block) |else_id|
            self.dom.isInLoop(else_id, loop_header)
        else
            false;
        const merge_in_loop = if (pattern.merge_block) |merge_id|
            self.dom.isInLoop(merge_id, loop_header)
        else
            false;
        const else_is_continuation = else_in_loop and !then_in_loop and !merge_in_loop;

        // Decompile the then body
        var skip_first = false;
        const then_body = try self.decompileLoopBody(
            pattern.then_block,
            loop_header,
            &skip_first,
            visited,
            if (merge_in_loop) pattern.merge_block else null,
        );

        // Decompile the else body if present
        const else_body = if (pattern.else_block) |else_id| blk: {
            if (else_is_continuation) break :blk &[_]*Stmt{};
            if (pattern.is_elif) {
                const else_pattern = self.analyzer.detectPattern(else_id);
                if (else_pattern == .if_stmt) {
                    const elif_stmt = try self.decompileLoopIf(else_pattern.if_stmt, loop_header, visited);
                    if (elif_stmt) |s| {
                        const body = try self.allocator.alloc(*Stmt, 1);
                        body[0] = s;
                        break :blk body;
                    }
                }
            }
            var skip = false;
            break :blk try self.decompileLoopBody(
                else_id,
                loop_header,
                &skip,
                visited,
                if (merge_in_loop) pattern.merge_block else null,
            );
        } else &[_]*Stmt{};

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .if_stmt = .{
            .condition = condition,
            .body = then_body,
            .else_body = else_body,
        } };

        return stmt;
    }

    /// Decompile a body within a loop using dominator-based membership.
    fn decompileLoopBody(
        self: *Decompiler,
        start_block: u32,
        loop_header: u32,
        skip_first_store: *bool,
        visited: *std.DynamicBitSet,
        stop_block: ?u32,
    ) ![]const *Stmt {
        var stmts: std.ArrayList(*Stmt) = .{};
        errdefer stmts.deinit(self.allocator);

        var block_idx = start_block;

        while (block_idx < self.cfg.blocks.len) {
            if (stop_block) |stop_id| {
                if (block_idx == stop_id) break;
            }
            // Use dominator tree for membership check
            if (!self.dom.isInLoop(block_idx, loop_header)) break;
            if (visited.isSet(block_idx)) break;
            visited.set(block_idx);

            const block = &self.cfg.blocks[block_idx];
            const has_back_edge = self.hasLoopBackEdge(block, loop_header);
            const pattern = self.analyzer.detectPattern(block_idx);

            switch (pattern) {
                .if_stmt => |p| {
                    try self.processPartialBlock(block, &stmts, skip_first_store);

                    const if_stmt = try self.decompileLoopIf(p, loop_header, visited);
                    if (if_stmt) |s| {
                        try stmts.append(self.allocator, s);
                    }

                    if (p.merge_block) |merge_id| {
                        if (stop_block) |stop_id| {
                            if (merge_id == stop_id) break;
                        }
                        if (!self.dom.isInLoop(merge_id, loop_header)) break;
                        block_idx = merge_id;
                        continue;
                    }

                    break;
                },
                else => {
                    // Process statements, stopping at back edge
                    try self.processBlockStatements(
                        block_idx,
                        block,
                        &stmts,
                        skip_first_store,
                        has_back_edge,
                        loop_header,
                    );
                    if (has_back_edge) break;

                    // Move to next block
                    if (block.successors.len == 0) break;

                    // Find the non-loop-back successor
                    var next_block: ?u32 = null;
                    for (block.successors) |edge| {
                        if (edge.edge_type != .loop_back) {
                            next_block = edge.target;
                            break;
                        }
                    }
                    if (next_block) |next_id| {
                        if (stop_block) |stop_id| {
                            if (next_id == stop_id) break;
                        }
                        block_idx = next_id;
                        continue;
                    }
                    break;
                },
            }
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    /// Create an assignment statement.
    fn makeAssign(self: *Decompiler, target: *Expr, value: *Expr) !*Stmt {
        const targets = try self.allocator.alloc(*Expr, 1);
        targets[0] = target;

        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .assign = .{
            .targets = targets,
            .value = value,
            .type_comment = null,
        } };
        return stmt;
    }

    /// Create a break statement.
    fn makeBreak(self: *Decompiler) !*Stmt {
        const stmt = try self.allocator.create(Stmt);
        stmt.* = .break_stmt;
        return stmt;
    }

    /// Create a continue statement.
    fn makeContinue(self: *Decompiler) !*Stmt {
        const stmt = try self.allocator.create(Stmt);
        stmt.* = .continue_stmt;
        return stmt;
    }

    /// Create a return statement.
    fn makeReturn(self: *Decompiler, value: *Expr) !*Stmt {
        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .return_stmt = .{
            .value = value,
        } };
        return stmt;
    }

    /// Create an expression statement.
    fn makeExprStmt(self: *Decompiler, value: *Expr) !*Stmt {
        const stmt = try self.allocator.create(Stmt);
        stmt.* = .{ .expr_stmt = .{
            .value = value,
        } };
        return stmt;
    }

    /// Check if a statement is `return None`.
    pub fn isReturnNone(stmt: *const Stmt) bool {
        if (stmt.* != .return_stmt) return false;
        const ret = stmt.return_stmt;
        if (ret.value) |val| {
            if (val.* == .constant) {
                return val.constant == .none;
            }
        }
        return false;
    }
};

/// Decompile a code object and write Python source to writer.
pub fn decompileToSource(allocator: Allocator, code: *const pyc.Code, version: Version, writer: anytype) !void {
    // Handle module-level code
    if (std.mem.eql(u8, code.name, "<module>")) {
        // Process imports first (TODO)

        // Process function/class definitions
        for (code.consts) |c| {
            if (c == .code) {
                try decompileFunctionToSource(allocator, c.code, version, writer, 0);
                try writer.writeByte('\n');
            }
        }
    } else {
        try decompileFunctionToSource(allocator, code, version, writer, 0);
    }
}

/// Decompile a function and write to writer.
fn decompileFunctionToSource(allocator: Allocator, code: *const pyc.Code, version: Version, writer: anytype, indent: u32) !void {
    // Write indent
    var i: u32 = 0;
    while (i < indent) : (i += 1) {
        try writer.writeAll("    ");
    }

    // Check for lambda
    if (codegen.isLambda(code)) {
        try writer.writeAll("# lambda\n");
        return;
    }

    // Write decorators (TODO: extract from bytecode)

    // Write async if coroutine
    if (codegen.isCoroutine(code)) {
        try writer.writeAll("async ");
    }

    // Write function signature
    try writer.writeAll("def ");
    try writer.writeAll(code.name);
    try writer.writeByte('(');

    // Write arguments
    var first = true;
    const posonly = code.posonlyargcount;
    const argcount = code.argcount;
    const kwonly = code.kwonlyargcount;

    // Position-only and regular args
    for (code.varnames[0..@min(argcount, code.varnames.len)], 0..) |name, idx| {
        if (!first) try writer.writeAll(", ");
        first = false;
        try writer.writeAll(name);

        if (posonly > 0 and idx == posonly - 1) {
            try writer.writeAll(", /");
        }
    }

    // Keyword-only args
    if (kwonly > 0 and argcount + kwonly <= code.varnames.len) {
        if (posonly == 0 and argcount > 0) {
            try writer.writeAll(", ");
        }
        if (argcount == posonly) {
            try writer.writeAll("*, ");
        }
        for (code.varnames[argcount .. argcount + kwonly], 0..) |name, idx| {
            if (idx > 0 or argcount > 0) try writer.writeAll(", ");
            try writer.writeAll(name);
        }
    }

    try writer.writeAll("):\n");

    // Write docstring
    if (codegen.extractDocstring(code)) |doc| {
        i = 0;
        while (i < indent + 1) : (i += 1) {
            try writer.writeAll("    ");
        }
        try writer.writeAll("\"\"\"");
        // Escape newlines in docstring
        for (doc) |c| {
            if (c == '\n') {
                try writer.writeByte('\n');
                var j: u32 = 0;
                while (j < indent + 1) : (j += 1) {
                    try writer.writeAll("    ");
                }
            } else {
                try writer.writeByte(c);
            }
        }
        try writer.writeAll("\"\"\"\n");
    }

    // Decompile function body
    if (code.code.len > 0) {
        var decompiler = try Decompiler.init(allocator, code, version);
        defer decompiler.deinit();

        const stmts = try decompiler.decompile();

        // Filter out trailing `return None` (implicit in Python)
        var effective_stmts = stmts;
        while (effective_stmts.len > 0 and Decompiler.isReturnNone(effective_stmts[effective_stmts.len - 1])) {
            effective_stmts = effective_stmts[0 .. effective_stmts.len - 1];
        }

        if (effective_stmts.len == 0) {
            // Empty body - write pass
            i = 0;
            while (i < indent + 1) : (i += 1) {
                try writer.writeAll("    ");
            }
            try writer.writeAll("pass\n");
        } else {
            // Write decompiled statements
            var cg = codegen.Writer.init(allocator);
            defer cg.deinit(allocator);
            cg.indent_level = indent + 1;

            for (effective_stmts) |stmt| {
                try cg.writeStmt(allocator, stmt);
            }

            const output = try cg.getOutput(allocator);
            defer allocator.free(output);
            try writer.writeAll(output);
        }
    } else {
        i = 0;
        while (i < indent + 1) : (i += 1) {
            try writer.writeAll("    ");
        }
        try writer.writeAll("pass\n");
    }

    // Process nested functions
    for (code.consts) |c| {
        if (c == .code) {
            const nested = c.code;
            if (!std.mem.eql(u8, nested.name, "<lambda>")) {
                try writer.writeByte('\n');
                try decompileFunctionToSource(allocator, nested, version, writer, indent + 1);
            }
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "decompiler init" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create minimal code object
    var code = pyc.Code{
        .allocator = allocator,
        .name = "test",
        .code = &.{},
    };

    const version = Version.init(3, 12);

    var decompiler = try Decompiler.init(allocator, &code, version);
    defer decompiler.deinit();

    try testing.expectEqual(@as(usize, 0), decompiler.cfg.blocks.len);
}
