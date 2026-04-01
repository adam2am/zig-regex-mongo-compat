const std = @import("std");
const RegexError = @import("errors.zig").RegexError;
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const ast = @import("ast.zig");
const common = @import("common.zig");
const optimizer = @import("optimizer.zig");
const backtrack = @import("backtrack.zig");
const unicode = @import("unicode.zig");
const bytecode = @import("bytecode.zig");
const pattern_analyzer = @import("pattern_analyzer.zig");
const execution_plan = @import("execution_plan.zig");
const text_policy = @import("text_policy.zig");
const match_types = @import("match_types.zig");
const semantic_validator = @import("semantic_validator.zig");

pub const EngineType = execution_plan.EngineType;
pub const InputValidationPolicy = execution_plan.InputValidationPolicy;
pub const MatchBuffer = match_types.MatchBuffer;
pub const MatchCapture = match_types.Capture;

/// Main regex type - represents a compiled regular expression pattern.
pub const Regex = struct {
    allocator: std.mem.Allocator,
    program: ?bytecode.BytecodeProgram, // New Bytecode VM program
    nfa: ?compiler.NFA, // Kept for legacy NFA graph (optional)
    ast: ?ast.AST,      // Kept for backtracking engine, contains its own arena
    capture_count: usize,
    named_captures: ?std.StringArrayHashMap(usize) = null,
    flags: common.CompileFlags,
    engine_type: EngineType,
    input_validation_policy: InputValidationPolicy,
    word_boundary_policy: text_policy.WordBoundaryPolicy,
    opt_info: optimizer.OptimizationInfo,

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        return compileWithFlags(allocator, pattern, .{});
    }

    pub fn compileWithFlags(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags) !Regex {
        for (pattern) |byte| if (byte == 0) return RegexError.InvalidPattern;

        var p = try parser.Parser.init(allocator, pattern, flags);
        defer p.deinit();
        var tree = try p.parse();
        errdefer tree.deinit();

        const final_flags = p.currentFlags();

        var opt = optimizer.Optimizer.init(allocator);
        var opt_info = try opt.analyze(tree.root);
        errdefer opt_info.deinit(allocator);

        var named_captures: ?std.StringArrayHashMap(usize) = null;
        try collectNamedCaptures(allocator, tree.root, &named_captures);
        try semantic_validator.validate(tree.root, tree.capture_count, if (named_captures) |*nc| nc else null);

        const plan = execution_plan.build(tree.root, final_flags);

        if (plan.analyzer_max_risk) |max_risk| {
            try pattern_analyzer.analyzeAndValidate(allocator, tree.root, max_risk);
        }

        if (plan.engine_type == .backtracking) {
            return Regex{
                .allocator = allocator,
                .program = null,
                .nfa = null,
                .ast = tree,
                .capture_count = tree.capture_count,
                .named_captures = named_captures,
                .flags = final_flags,
                .engine_type = .backtracking,
                .input_validation_policy = plan.input_validation_policy,
                .word_boundary_policy = plan.word_boundary_policy,
                .opt_info = opt_info,
            };
        } else {
            var b_comp = bytecode.BytecodeCompiler.init(allocator, tree.capture_count);
            defer b_comp.deinit();
            const program = try b_comp.compile(tree.root);

            tree.deinit();

            return Regex{
                .allocator = allocator,
                .program = program,
                .nfa = null,
                .ast = null,
                .capture_count = program.capture_count,
                .named_captures = named_captures,
                .flags = final_flags,
                .engine_type = .thompson_nfa,
                .input_validation_policy = plan.input_validation_policy,
                .word_boundary_policy = plan.word_boundary_policy,
                .opt_info = opt_info,
            };
        }
    }

    pub fn deinit(self: *Regex) void {
        if (self.program) |p| p.deinit();
        if (self.nfa) |*n| n.deinit();
        if (self.ast) |*tree| tree.deinit();
        self.opt_info.deinit(self.allocator);
        if (self.named_captures) |*nc| {
            for (nc.keys()) |key| self.allocator.free(key);
            nc.deinit();
        }
    }

    pub fn session(self: *const Regex, allocator: std.mem.Allocator) !ExecutionSession {
        return ExecutionSession.init(allocator, self);
    }

    pub fn matchBuffer(self: *const Regex, allocator: std.mem.Allocator) !MatchBuffer {
        return MatchBuffer.init(allocator, self.capture_count);
    }

    /// Compatibility wrapper for the older Matcher API. Prefer `session()` in new code.
    pub fn matcher(self: *const Regex, allocator: std.mem.Allocator) !Matcher {
        return self.session(allocator);
    }

    pub fn iterator(self: *const Regex, input: []const u8) MatchIterator {
        return MatchIterator.init(self, input);
    }

    pub fn getCaptureIndex(self: *const Regex, name: []const u8) ?usize {
        return if (self.named_captures) |nc| nc.get(name) else null;
    }

    pub fn getNamedCapture(self: *const Regex, match: *const Match, name: []const u8) ?[]const u8 {
        const index = self.getCaptureIndex(name) orelse return null;
        if (index == 0 or index > match.captures.len) return null;
        return match.captures[index - 1];
    }

    pub fn isMatch(self: *const Regex, input: []const u8) !bool {
        var runtime = try Regex.session(self, self.allocator);
        defer runtime.deinit();
        return runtime.isMatch(input);
    }

    pub fn find(self: *const Regex, input: []const u8) !?Match {
        var runtime = try Regex.session(self, self.allocator);
        defer runtime.deinit();
        return runtime.find(input);
    }

    pub fn findInto(self: *const Regex, input: []const u8, buffer: *MatchBuffer) !bool {
        var runtime = try Regex.session(self, self.allocator);
        defer runtime.deinit();
        return runtime.findInto(input, buffer);
    }

    pub fn findAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match {
        return findAllImpl(self, allocator, input);
    }

    fn validateInput(self: *const Regex, input: []const u8) !void {
        switch (self.input_validation_policy) {
            .strict_utf8 => try text_policy.validateUtf8(input),
            .engine_defined => {},
        }
    }

    pub fn replace(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        return replaceImpl(self, allocator, input, replacement);
    }

    pub fn replaceAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        return replaceAllImpl(self, allocator, input, replacement);
    }

    pub fn split(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
        return splitImpl(self, allocator, input);
    }
};

/// Match result. Note: `captures` contains the text of each group.
pub const Match = struct {
    slice: []const u8,
    start: usize,
    end: usize,
    captures: []const []const u8,

    pub fn deinit(self: Match, allocator: std.mem.Allocator) void {
        allocator.free(self.captures);
    }
};

/// Simple allocating iterator for backwards-compatible call sites.
/// For high-throughput loops, prefer `ExecutionSession.iterator(...).nextInto(...)`.
pub const MatchIterator = struct {
    regex: *const Regex,
    input: []const u8,
    pos: usize,

    pub fn init(regex: *const Regex, input: []const u8) MatchIterator {
        return .{
            .regex = regex,
            .input = input,
            .pos = 0,
        };
    }

    pub fn deinit(self: *MatchIterator) void {
        _ = self;
    }

    pub fn reset(self: *MatchIterator) void {
        self.pos = 0;
    }

    pub fn next(self: *MatchIterator, allocator: std.mem.Allocator) !?Match {
        if (self.pos > self.input.len) return null;

        var session = try self.regex.session(allocator);
        defer session.deinit();

        if (try session.find(self.input[self.pos..])) |match| {
            var corrected = match;
            corrected.start += self.pos;
            corrected.end += self.pos;
            corrected.slice = self.input[corrected.start..corrected.end];
            self.pos = if (corrected.end > corrected.start) corrected.end else advanceInputPosition(self.input, corrected.start);
            return corrected;
        }
        return null;
    }
};

pub const SessionIterator = struct {
    session: *ExecutionSession,
    input: []const u8,
    pos: usize,
    validated: bool,

    pub fn init(session: *ExecutionSession, input: []const u8) SessionIterator {
        return .{
            .session = session,
            .input = input,
            .pos = 0,
            .validated = false,
        };
    }

    pub fn reset(self: *SessionIterator) void {
        self.pos = 0;
        self.validated = false;
    }

    pub fn nextInto(self: *SessionIterator, buffer: *MatchBuffer) !bool {
        if (!self.validated) {
            try self.session.regex.validateInput(self.input);
            self.validated = true;
        }

        if (self.pos > self.input.len) {
            buffer.reset();
            return false;
        }

        if (try self.session.findIntoAssumeValid(self.input[self.pos..], buffer)) {
            buffer.start += self.pos;
            buffer.end += self.pos;
            buffer.slice = self.input[buffer.start..buffer.end];
            self.pos = if (buffer.end > buffer.start) buffer.end else advanceInputPosition(self.input, buffer.start);
            return true;
        }

        buffer.reset();
        self.pos = self.input.len + 1;
        return false;
    }

    pub fn next(self: *SessionIterator, allocator: std.mem.Allocator) !?Match {
        var buffer = try self.session.regex.matchBuffer(allocator);
        defer buffer.deinit();

        if (!(try self.nextInto(&buffer))) return null;
        return try materializeMatchFromBuffer(allocator, &buffer);
    }
};

pub const ExecutionSession = struct {
    regex: *const Regex,
    allocator: std.mem.Allocator,
    /// Reusable scratch storage for the allocating `find()` convenience path.
    scratch_match: MatchBuffer,
    engine: union(enum) {
        nfa: vm.BytecodeVM,
        backtrack: backtrack.BacktrackEngine,
    },

    pub fn init(allocator: std.mem.Allocator, regex: *const Regex) !ExecutionSession {
        return switch (regex.engine_type) {
            .thompson_nfa => blk: {
                var engine = try vm.BytecodeVM.init(allocator, regex.program.?, regex.word_boundary_policy, regex.input_validation_policy == .strict_utf8);
                errdefer engine.deinit();

                const scratch_match = try MatchBuffer.init(allocator, regex.capture_count);
                break :blk .{
                    .regex = regex,
                    .allocator = allocator,
                    .scratch_match = scratch_match,
                    .engine = .{ .nfa = engine },
                };
            },
            .backtracking => blk: {
                var engine = try backtrack.BacktrackEngine.init(allocator, regex.ast.?.root, regex.capture_count, regex.flags, if (regex.named_captures) |*nc| nc else null, regex.word_boundary_policy, regex.input_validation_policy == .strict_utf8);
                errdefer engine.deinit();

                const scratch_match = try MatchBuffer.init(allocator, regex.capture_count);
                break :blk .{
                    .regex = regex,
                    .allocator = allocator,
                    .scratch_match = scratch_match,
                    .engine = .{ .backtrack = engine },
                };
            },
        };
    }

    pub fn deinit(self: *ExecutionSession) void {
        switch (self.engine) {
            .nfa => |*e| e.deinit(),
            .backtrack => |*e| e.deinit(),
        }
        self.scratch_match.deinit();
    }

    pub fn setMaxSteps(self: *ExecutionSession, max_steps: usize) void {
        switch (self.engine) {
            .nfa => {},
            .backtrack => |*engine| engine.max_steps = max_steps,
        }
    }

    pub fn iterator(self: *ExecutionSession, input: []const u8) SessionIterator {
        return SessionIterator.init(self, input);
    }

    pub fn isMatch(self: *ExecutionSession, input: []const u8) !bool {
        try self.regex.validateInput(input);
        return switch (self.engine) {
            .nfa => |*e| blk: {
                var search_pos: usize = 0;
                while (search_pos <= input.len) {
                    if (try e.matchAt(input, search_pos, null)) {
                        break :blk true;
                    }
                    if (search_pos >= input.len) break;
                    search_pos += (unicode.decodeUtf8(input[search_pos..]) catch return error.InvalidUtf8).len;
                }
                break :blk false;
            },
            .backtrack => |*e| try e.isMatch(input),
        };
    }

    pub fn find(self: *ExecutionSession, input: []const u8) !?Match {
        try self.regex.validateInput(input);

        if (!(try self.findIntoAssumeValid(input, &self.scratch_match))) return null;
        return try materializeMatchFromBuffer(self.allocator, &self.scratch_match);
    }

    pub fn findInto(self: *ExecutionSession, input: []const u8, buffer: *MatchBuffer) !bool {
        try self.regex.validateInput(input);
        return self.findIntoAssumeValid(input, buffer);
    }

    fn findIntoAssumeValid(self: *ExecutionSession, input: []const u8, buffer: *MatchBuffer) !bool {
        if (buffer.captures.len != self.regex.capture_count) return RegexError.InvalidArgument;

        buffer.reset();

        return switch (self.engine) {
            .nfa => |*e| blk: {
                // Optimization: Literal prefix scan
                if (!self.regex.flags.case_insensitive) {
                    if (self.regex.opt_info.literal_prefix) |prefix| {
                        if (prefix.len > 0 and prefix[0] < 128) {
                            const first: u8 = @intCast(prefix[0]);
                            var search_pos: usize = 0;
                            while (std.mem.indexOfScalar(u8, input[search_pos..], first)) |rel| {
                                const abs = search_pos + rel;
                                var end_pos: usize = undefined;
                                if (try e.matchAtInto(input, abs, buffer.captures, &end_pos)) {
                                    buffer.start = abs;
                                    buffer.end = end_pos;
                                    buffer.slice = input[abs..end_pos];
                                    buffer.matched = true;
                                    break :blk true;
                                }
                                search_pos = abs + 1;
                            }
                            break :blk false;
                        }
                    }
                }

                var search_pos: usize = 0;
                while (search_pos <= input.len) {
                    var end_pos: usize = undefined;
                    if (try e.matchAtInto(input, search_pos, buffer.captures, &end_pos)) {
                        buffer.start = search_pos;
                        buffer.end = end_pos;
                        buffer.slice = input[search_pos..end_pos];
                        buffer.matched = true;
                        break :blk true;
                    }
                    if (search_pos >= input.len) break;
                    search_pos += (unicode.decodeUtf8(input[search_pos..]) catch break).len;
                }
                break :blk false;
            },
            .backtrack => |*e| blk: {
                var start_pos: usize = undefined;
                var end_pos: usize = undefined;
                if (try e.findInto(input, buffer.captures, &start_pos, &end_pos)) {
                    buffer.start = start_pos;
                    buffer.end = end_pos;
                    buffer.slice = input[start_pos..end_pos];
                    buffer.matched = true;
                    break :blk true;
                }
                break :blk false;
            },
        };
    }

};

/// Compatibility alias. Prefer `ExecutionSession` in new code.
pub const Matcher = ExecutionSession;

fn collectNamedCaptures(allocator: std.mem.Allocator, node: *ast.Node, map: *?std.StringArrayHashMap(usize)) !void {
    switch (node.node_type) {
        .concat => {
            try collectNamedCaptures(allocator, node.data.concat.left, map);
            try collectNamedCaptures(allocator, node.data.concat.right, map);
        },
        .alternation => {
            try collectNamedCaptures(allocator, node.data.alternation.left, map);
            try collectNamedCaptures(allocator, node.data.alternation.right, map);
        },
        .star => try collectNamedCaptures(allocator, node.data.star.child, map),
        .plus => try collectNamedCaptures(allocator, node.data.plus.child, map),
        .optional => try collectNamedCaptures(allocator, node.data.optional.child, map),
        .repeat => try collectNamedCaptures(allocator, node.data.repeat.child, map),
        .group => {
            if (node.data.group.name) |name| {
                if (node.data.group.capture_index) |idx| {
                    if (map.* == null) {
                        map.* = std.StringArrayHashMap(usize).init(allocator);
                    }
                    if (map.*.?.get(name) == null) {
                        const owned_name = try allocator.dupe(u8, name);
                        try map.*.?.put(owned_name, idx);
                    }
                }
            }
            try collectNamedCaptures(allocator, node.data.group.child, map);
        },
        else => {},
    }
}

fn replaceImpl(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
    try self.validateInput(input);

    var session = try self.session(allocator);
    defer session.deinit();

    var buffer = try self.matchBuffer(allocator);
    defer buffer.deinit();

    if (!(try session.findIntoAssumeValid(input, &buffer))) {
        return try allocator.dupe(u8, input);
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, input[0..buffer.start]);
    try appendExpandedReplacementFromBuffer(&result, allocator, replacement, buffer.captures, buffer.slice);
    try result.appendSlice(allocator, input[buffer.end..]);
    return result.toOwnedSlice(allocator);
}

fn replaceAllImpl(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
    try self.validateInput(input);

    var session = try self.session(allocator);
    defer session.deinit();

    var buffer = try self.matchBuffer(allocator);
    defer buffer.deinit();

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    var last: usize = 0;
    var matched_any = false;
    while (pos <= input.len) {
        if (try session.findIntoAssumeValid(input[pos..], &buffer)) {
            buffer.start += pos;
            buffer.end += pos;
            buffer.slice = input[buffer.start..buffer.end];

            matched_any = true;
            try result.appendSlice(allocator, input[last..buffer.start]);
            try appendExpandedReplacementFromBuffer(&result, allocator, replacement, buffer.captures, buffer.slice);
            last = buffer.end;
            pos = if (buffer.end > buffer.start) buffer.end else advanceInputPosition(input, buffer.start);
            continue;
        }
        break;
    }

    if (!matched_any) {
        return try allocator.dupe(u8, input);
    }

    try result.appendSlice(allocator, input[last..]);
    return result.toOwnedSlice(allocator);
}

fn findAllImpl(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match {
    try self.validateInput(input);

    var list: std.ArrayList(Match) = .empty;
    defer list.deinit(allocator);

    var session = try self.session(allocator);
    defer session.deinit();

    var buffer = try self.matchBuffer(allocator);
    defer buffer.deinit();

    var pos: usize = 0;
    while (pos <= input.len) {
        if (try session.findIntoAssumeValid(input[pos..], &buffer)) {
            buffer.start += pos;
            buffer.end += pos;
            buffer.slice = input[buffer.start..buffer.end];

            const next_pos = if (buffer.end > buffer.start) buffer.end else advanceInputPosition(input, buffer.start);
            try list.append(allocator, try materializeMatchFromBuffer(allocator, &buffer));
            pos = next_pos;
            continue;
        }
        break;
    }

    return list.toOwnedSlice(allocator);
}

fn materializeMatchFromBuffer(allocator: std.mem.Allocator, buffer: *const MatchBuffer) !Match {
    const captures = try allocator.alloc([]const u8, buffer.captures.len);
    for (buffer.captures, 0..) |capture, i| {
        captures[i] = capture.text;
    }
    return .{
        .slice = buffer.slice,
        .start = buffer.start,
        .end = buffer.end,
        .captures = captures,
    };
}

fn splitImpl(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    try self.validateInput(input);

    var session = try self.session(allocator);
    defer session.deinit();

    var buffer = try self.matchBuffer(allocator);
    defer buffer.deinit();

    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);

    var pos: usize = 0;
    var last: usize = 0;
    while (pos <= input.len) {
        if (try session.findIntoAssumeValid(input[pos..], &buffer)) {
            buffer.start += pos;
            buffer.end += pos;
            buffer.slice = input[buffer.start..buffer.end];

            try parts.append(allocator, input[last..buffer.start]);
            last = buffer.end;
            pos = if (buffer.end > buffer.start) buffer.end else advanceInputPosition(input, buffer.start);
            continue;
        }
        break;
    }

    try parts.append(allocator, input[last..]);
    return parts.toOwnedSlice(allocator);
}

fn advanceInputPosition(input: []const u8, pos: usize) usize {
    if (pos >= input.len) return pos + 1;
    return pos + (unicode.decodeUtf8(input[pos..]) catch return pos + 1).len;
}

fn isAsciiDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn appendExpandedReplacementFromBuffer(result: *std.ArrayList(u8), allocator: std.mem.Allocator, replacement: []const u8, captures: []const MatchCapture, match_slice: []const u8) !void {
    var i: usize = 0;
    while (i < replacement.len) {
        if (replacement[i] == '$') {
            i += 1;
            if (i >= replacement.len) {
                try result.append(allocator, '$');
                break;
            }
            if (replacement[i] == '$') {
                try result.append(allocator, '$');
                i += 1;
            } else if (replacement[i] == '&' or replacement[i] == '0') {
                try result.appendSlice(allocator, match_slice);
                i += 1;
            } else if (isAsciiDigit(replacement[i])) {
                var group_idx: usize = replacement[i] - '0';
                i += 1;
                while (i < replacement.len and isAsciiDigit(replacement[i])) {
                    group_idx = group_idx * 10 + (replacement[i] - '0');
                    i += 1;
                }
                if (group_idx > 0 and group_idx <= captures.len) {
                    try result.appendSlice(allocator, captures[group_idx - 1].text);
                } else {
                    try result.append(allocator, '$');
                    const digits = try std.fmt.allocPrint(allocator, "{d}", .{group_idx});
                    defer allocator.free(digits);
                    try result.appendSlice(allocator, digits);
                }
            } else {
                try result.append(allocator, '$');
            }
        } else {
            try result.append(allocator, replacement[i]);
            i += 1;
        }
    }
}
