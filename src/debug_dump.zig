const std = @import("std");
const pyc = @import("pyc.zig");
const cfg_mod = @import("cfg.zig");
const dom_mod = @import("dom.zig");
const ctrl = @import("ctrl.zig");
const decoder = @import("decoder.zig");

const Allocator = std.mem.Allocator;
const DumpError = anyerror;

pub const Sections = struct {
    bytecode: bool = false,
    cfg: bool = false,
    dom: bool = false,
    loops: bool = false,
    patterns: bool = false,
    passes: bool = false,

    pub fn any(self: Sections) bool {
        return self.bytecode or self.cfg or self.dom or self.loops or self.patterns or self.passes;
    }
};

pub fn parseSections(raw: ?[]const u8) !Sections {
    var sections = Sections{};
    if (raw == null or raw.?.len == 0) {
        sections.bytecode = true;
        sections.cfg = true;
        sections.dom = true;
        sections.loops = true;
        sections.patterns = true;
        sections.passes = true;
        return sections;
    }

    var it = std.mem.splitScalar(u8, raw.?, ',');
    while (it.next()) |item| {
        const name = std.mem.trim(u8, item, " \t\r\n");
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, "all")) {
            sections.bytecode = true;
            sections.cfg = true;
            sections.dom = true;
            sections.loops = true;
            sections.patterns = true;
            sections.passes = true;
        } else if (std.mem.eql(u8, name, "bytecode")) {
            sections.bytecode = true;
        } else if (std.mem.eql(u8, name, "cfg")) {
            sections.cfg = true;
        } else if (std.mem.eql(u8, name, "dom")) {
            sections.dom = true;
        } else if (std.mem.eql(u8, name, "loops")) {
            sections.loops = true;
        } else if (std.mem.eql(u8, name, "patterns")) {
            sections.patterns = true;
        } else if (std.mem.eql(u8, name, "passes")) {
            sections.passes = true;
        } else {
            return error.UnknownDumpSection;
        }
    }
    return sections;
}

pub fn dumpModule(
    allocator: Allocator,
    code: *const pyc.Code,
    version: decoder.Version,
    sections: Sections,
    writer: anytype,
) !void {
    const dump = try buildCodeDump(allocator, code, version, sections);
    defer dump.deinit(allocator);
    try std.json.Stringify.value(dump, .{}, writer);
}

const Dump = struct {
    meta: Meta,
    code: CodeDump,

    fn deinit(self: *const Dump, allocator: Allocator) void {
        self.code.deinit(allocator);
    }
};

const Meta = struct {
    major: u16,
    minor: u16,
};

const CodeDump = struct {
    name: []const u8,
    qualname: ?[]const u8,
    firstlineno: u32,
    argcount: u32,
    nlocals: u32,
    stacksize: u32,
    flags: u32,
    bytecode: ?[]const InstDump,
    cfg: ?CfgDump,
    dom: ?DomDump,
    patterns: ?[]const PatternDump,
    passes: ?PassDump,
    children: ?[]const CodeDump,

    fn deinit(self: *const CodeDump, allocator: Allocator) void {
        if (self.bytecode) |items| allocator.free(items);
        if (self.cfg) |*cfg| cfg.deinit(allocator);
        if (self.dom) |*dom| dom.deinit(allocator);
        if (self.patterns) |items| allocator.free(items);
        if (self.passes) |*passes| passes.deinit(allocator);
        if (self.children) |items| {
            for (items) |*child| child.deinit(allocator);
            allocator.free(items);
        }
    }
};

const InstDump = struct {
    offset: u32,
    op: []const u8,
    arg: u32,
    size: u16,
    cache: u8,
    jump_target: ?u32,
    is_jump: bool,
    is_cond: bool,
};

const EdgeDump = struct {
    target: u32,
    edge: []const u8,
};

const BlockDump = struct {
    id: u32,
    start_offset: u32,
    end_offset: u32,
    is_loop_header: bool,
    is_exception_handler: bool,
    predecessors: []const u32,
    successors: []const EdgeDump,
    instructions: []const InstDump,

    fn deinit(self: *const BlockDump, allocator: Allocator) void {
        allocator.free(self.predecessors);
        allocator.free(self.successors);
        allocator.free(self.instructions);
    }
};

const CfgDump = struct {
    entry: u32,
    blocks: []const BlockDump,

    fn deinit(self: *const CfgDump, allocator: Allocator) void {
        for (self.blocks) |*blk| blk.deinit(allocator);
        allocator.free(self.blocks);
    }
};

const LoopDump = struct {
    header: u32,
    body: []const u32,
};

const DomDump = struct {
    idom: []const u32,
    loops: []const LoopDump,

    fn deinit(self: *const DomDump, allocator: Allocator) void {
        allocator.free(self.idom);
        for (self.loops) |loop| allocator.free(loop.body);
        allocator.free(self.loops);
    }
};

const PatternDump = struct {
    block: u32,
    kind: []const u8,
    then_block: ?u32 = null,
    else_block: ?u32 = null,
    merge_block: ?u32 = null,
    body_block: ?u32 = null,
    exit_block: ?u32 = null,
    handlers: ?u32 = null,
    cleanup_block: ?u32 = null,
    cases: ?u32 = null,
    is_elif: ?bool = null,
};

const PatternCounts = struct {
    if_stmt: u32 = 0,
    while_loop: u32 = 0,
    for_loop: u32 = 0,
    try_stmt: u32 = 0,
    with_stmt: u32 = 0,
    match_stmt: u32 = 0,
    sequential: u32 = 0,
    unknown: u32 = 0,
};

const PassDump = struct {
    stages: []const []const u8,
    patterns: PatternCounts,
    unreachable_blocks: []const u32,

    fn deinit(self: *const PassDump, allocator: Allocator) void {
        allocator.free(self.stages);
        allocator.free(self.unreachable_blocks);
    }
};

fn buildCodeDump(allocator: Allocator, code: *const pyc.Code, version: decoder.Version, sections: Sections) DumpError!Dump {
    const child_list = try collectChildren(allocator, code, version, sections);
    var code_dump = CodeDump{
        .name = code.name,
        .qualname = if (code.qualname.len > 0) code.qualname else null,
        .firstlineno = code.firstlineno,
        .argcount = code.argcount,
        .nlocals = code.nlocals,
        .stacksize = code.stacksize,
        .flags = code.flags,
        .bytecode = null,
        .cfg = null,
        .dom = null,
        .patterns = null,
        .passes = null,
        .children = child_list,
    };

    var cfg: ?cfg_mod.CFG = null;
    var dom: ?dom_mod.DomTree = null;
    var analyzer: ?ctrl.Analyzer = null;
    defer {
        if (analyzer) |*a| a.deinit();
        if (dom) |*d| d.deinit();
        if (cfg) |*c| c.deinit();
    }

    if (sections.bytecode) {
        code_dump.bytecode = try collectInsts(allocator, code, version);
    }

    if (sections.cfg or sections.dom or sections.loops or sections.patterns or sections.passes) {
        cfg = if (version.gte(3, 11) and code.exceptiontable.len > 0)
            try cfg_mod.buildCFGWithExceptions(allocator, code.code, code.exceptiontable, version)
        else
            try cfg_mod.buildCFG(allocator, code.code, version);

        const cfg_ref = cfg.?;
        if (sections.cfg) {
            code_dump.cfg = try buildCfgDump(allocator, &cfg_ref, version);
        }

        if (sections.dom or sections.loops or sections.patterns or sections.passes) {
            dom = try dom_mod.DomTree.init(allocator, &cfg_ref);
            const dom_ref = dom.?;
            if (sections.dom or sections.loops) {
                code_dump.dom = try buildDomDump(allocator, &dom_ref);
            }
            if (sections.patterns or sections.passes) {
                analyzer = try ctrl.Analyzer.init(allocator, &cfg_ref, &dom_ref);
                const analyzer_ref = &analyzer.?;
                if (sections.patterns) {
                    code_dump.patterns = try buildPatternDump(allocator, analyzer_ref);
                }
                if (sections.passes) {
                    code_dump.passes = try buildPassDump(allocator, &cfg_ref, analyzer_ref);
                }
            }
        }
    }

    return Dump{
        .meta = .{ .major = @intCast(version.major), .minor = @intCast(version.minor) },
        .code = code_dump,
    };
}

fn collectChildren(allocator: Allocator, code: *const pyc.Code, version: decoder.Version, sections: Sections) DumpError!?[]const CodeDump {
    var children: std.ArrayList(CodeDump) = .{};
    errdefer {
        for (children.items) |*child| child.deinit(allocator);
        children.deinit(allocator);
    }
    for (code.consts) |obj| {
        const child_code = switch (obj) {
            .code => |c| c,
            .code_ref => |c| c,
            else => null,
        };
        if (child_code) |child| {
            const dump = try buildCodeDump(allocator, child, version, sections);
            try children.append(allocator, dump.code);
        }
    }
    if (children.items.len == 0) return null;
    const slice = try children.toOwnedSlice(allocator);
    return slice;
}

fn collectInsts(allocator: Allocator, code: *const pyc.Code, version: decoder.Version) ![]const InstDump {
    var iter = decoder.InstructionIterator.init(code.code, version);
    var out: std.ArrayList(InstDump) = .{};
    errdefer out.deinit(allocator);

    while (iter.next()) |inst| {
        const jump_target = inst.jumpTarget(version);
        try out.append(allocator, .{
            .offset = inst.offset,
            .op = inst.opcode.name(),
            .arg = inst.arg,
            .size = inst.size,
            .cache = inst.cache_entries,
            .jump_target = jump_target,
            .is_jump = inst.isJump(),
            .is_cond = inst.isConditionalJump(),
        });
    }

    return out.toOwnedSlice(allocator);
}

fn buildCfgDump(allocator: Allocator, cfg: *const cfg_mod.CFG, version: decoder.Version) !CfgDump {
    var blocks_out: std.ArrayList(BlockDump) = .{};
    errdefer {
        for (blocks_out.items) |*blk| blk.deinit(allocator);
        blocks_out.deinit(allocator);
    }

    for (cfg.blocks, 0..) |*blk, idx| {
        var preds: std.ArrayList(u32) = .{};
        errdefer preds.deinit(allocator);
        for (blk.predecessors) |pid| {
            try preds.append(allocator, pid);
        }

        var succs: std.ArrayList(EdgeDump) = .{};
        errdefer succs.deinit(allocator);
        for (blk.successors) |edge| {
            try succs.append(allocator, .{
                .target = edge.target,
                .edge = edgeTypeName(edge.edge_type),
            });
        }

        var insts: std.ArrayList(InstDump) = .{};
        errdefer insts.deinit(allocator);
        for (blk.instructions) |inst| {
            try insts.append(allocator, .{
                .offset = inst.offset,
                .op = inst.opcode.name(),
                .arg = inst.arg,
                .size = inst.size,
                .cache = inst.cache_entries,
                .jump_target = inst.jumpTarget(version),
                .is_jump = inst.isJump(),
                .is_cond = inst.isConditionalJump(),
            });
        }

        try blocks_out.append(allocator, .{
            .id = @intCast(idx),
            .start_offset = blk.start_offset,
            .end_offset = blk.end_offset,
            .is_loop_header = blk.is_loop_header,
            .is_exception_handler = blk.is_exception_handler,
            .predecessors = try preds.toOwnedSlice(allocator),
            .successors = try succs.toOwnedSlice(allocator),
            .instructions = try insts.toOwnedSlice(allocator),
        });
    }

    return .{
        .entry = cfg.entry,
        .blocks = try blocks_out.toOwnedSlice(allocator),
    };
}

fn buildDomDump(allocator: Allocator, dom: *const dom_mod.DomTree) !DomDump {
    var loops: std.ArrayList(LoopDump) = .{};
    errdefer {
        for (loops.items) |loop| allocator.free(loop.body);
        loops.deinit(allocator);
    }

    var it = dom.loop_bodies.iterator();
    while (it.next()) |entry| {
        const header = entry.key_ptr.*;
        const body_set = entry.value_ptr.*;
        var body: std.ArrayList(u32) = .{};
        errdefer body.deinit(allocator);
        var bit_it = body_set.iterator(.{});
        while (bit_it.next()) |bit| {
            try body.append(allocator, @intCast(bit));
        }
        try loops.append(allocator, .{ .header = header, .body = try body.toOwnedSlice(allocator) });
    }

    return .{
        .idom = try allocator.dupe(u32, dom.idom),
        .loops = try loops.toOwnedSlice(allocator),
    };
}

fn buildPatternDump(allocator: Allocator, analyzer: *ctrl.Analyzer) ![]const PatternDump {
    var out: std.ArrayList(PatternDump) = .{};
    errdefer out.deinit(allocator);

    for (analyzer.cfg.blocks, 0..) |_, idx| {
        const bid: u32 = @intCast(idx);
        const pat = try analyzer.detectPattern(bid);
        switch (pat) {
            .if_stmt => |p| try out.append(allocator, .{
                .block = bid,
                .kind = "if",
                .then_block = p.then_block,
                .else_block = p.else_block,
                .merge_block = p.merge_block,
                .is_elif = p.is_elif,
            }),
            .while_loop => |p| try out.append(allocator, .{
                .block = bid,
                .kind = "while",
                .body_block = p.body_block,
                .exit_block = p.exit_block,
            }),
            .for_loop => |p| try out.append(allocator, .{
                .block = bid,
                .kind = "for",
                .body_block = p.body_block,
                .exit_block = p.exit_block,
            }),
            .try_stmt => |p| {
                const count: u32 = @intCast(p.handlers.len);
                try out.append(allocator, .{
                    .block = bid,
                    .kind = "try",
                    .handlers = count,
                    .else_block = p.else_block,
                    .exit_block = p.exit_block,
                });
                if (p.handlers_owned) {
                    analyzer.allocator.free(p.handlers);
                }
            },
            .with_stmt => |p| try out.append(allocator, .{
                .block = bid,
                .kind = "with",
                .body_block = p.body_block,
                .cleanup_block = p.cleanup_block,
                .exit_block = p.exit_block,
            }),
            .match_stmt => |p| {
                const count: u32 = @intCast(p.case_blocks.len);
                try out.append(allocator, .{
                    .block = bid,
                    .kind = "match",
                    .cases = count,
                    .exit_block = p.exit_block,
                });
                p.deinit(analyzer.allocator);
            },
            .sequential => try out.append(allocator, .{
                .block = bid,
                .kind = "sequential",
            }),
            .unknown => try out.append(allocator, .{
                .block = bid,
                .kind = "unknown",
            }),
        }
    }

    return out.toOwnedSlice(allocator);
}

fn buildPassDump(allocator: Allocator, cfg: *const cfg_mod.CFG, analyzer: *ctrl.Analyzer) !PassDump {
    var counts = PatternCounts{};
    var dead_blocks: std.ArrayList(u32) = .{};
    errdefer dead_blocks.deinit(allocator);

    for (cfg.blocks, 0..) |blk, idx| {
        if (idx != cfg.entry and blk.predecessors.len == 0) {
            try dead_blocks.append(allocator, @intCast(idx));
        }
        const pat = try analyzer.detectPattern(@intCast(idx));
        switch (pat) {
            .if_stmt => counts.if_stmt += 1,
            .while_loop => counts.while_loop += 1,
            .for_loop => counts.for_loop += 1,
            .try_stmt => |p| {
                counts.try_stmt += 1;
                if (p.handlers_owned) {
                    analyzer.allocator.free(p.handlers);
                }
            },
            .with_stmt => counts.with_stmt += 1,
            .match_stmt => |p| {
                counts.match_stmt += 1;
                p.deinit(analyzer.allocator);
            },
            .sequential => counts.sequential += 1,
            .unknown => counts.unknown += 1,
        }
    }

    const stages = try allocator.dupe([]const u8, &.{
        "decode",
        "cfg",
        "dom",
        "patterns",
    });

    return .{
        .stages = stages,
        .patterns = counts,
        .unreachable_blocks = try dead_blocks.toOwnedSlice(allocator),
    };
}

fn edgeTypeName(edge: cfg_mod.EdgeType) []const u8 {
    return switch (edge) {
        .normal => "normal",
        .conditional_true => "true",
        .conditional_false => "false",
        .loop_back => "loop_back",
        .exception => "exception",
    };
}
