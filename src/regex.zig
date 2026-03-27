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

pub const EngineType = execution_plan.EngineType;
pub const InputValidationPolicy = execution_plan.InputValidationPolicy;

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

    pub fn matcher(self: *const Regex, allocator: std.mem.Allocator) !Matcher {
        return Matcher.init(allocator, self);
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
        try self.validateInput(input);
        var compiled_matcher = try self.matcher(self.allocator);
        defer compiled_matcher.deinit();
        return compiled_matcher.isMatch(input);
    }

    pub fn find(self: *const Regex, input: []const u8) !?Match {
        try self.validateInput(input);
        var compiled_matcher = try self.matcher(self.allocator);
        defer compiled_matcher.deinit();
        return compiled_matcher.find(input);
    }

    pub fn findAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match {
        try self.validateInput(input);
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

        var matcher = try self.regex.matcher(allocator);
        defer matcher.deinit();

        if (try matcher.find(self.input[self.pos..])) |match| {
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

pub const Matcher = struct {
    regex: *const Regex,
    allocator: std.mem.Allocator,
    engine: union(enum) {
        nfa: vm.BytecodeVM,
        backtrack: backtrack.BacktrackEngine,
    },

    pub fn init(allocator: std.mem.Allocator, regex: *const Regex) !Matcher {
        return switch (regex.engine_type) {
            .thompson_nfa => .{
                .regex = regex,
                .allocator = allocator,
                .engine = .{ .nfa = try vm.BytecodeVM.init(allocator, regex.program.?, regex.word_boundary_policy) },
            },
            .backtracking => .{
                .regex = regex,
                .allocator = allocator,
                .engine = .{ .backtrack = try backtrack.BacktrackEngine.init(allocator, regex.ast.?.root, regex.capture_count, regex.flags, if (regex.named_captures) |*nc| nc else null, regex.word_boundary_policy) },
            },
        };
    }

    pub fn deinit(self: *Matcher) void {
        switch (self.engine) {
            .nfa => |*e| e.deinit(),
            .backtrack => |*e| e.deinit(),
        }
    }

    pub fn isMatch(self: *Matcher, input: []const u8) !bool {
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

    pub fn find(self: *Matcher, input: []const u8) !?Match {
        // Optimization: Literal prefix scan
        if (self.regex.engine_type == .thompson_nfa and !self.regex.flags.case_insensitive) {
            if (self.regex.opt_info.literal_prefix) |prefix| {
                if (prefix.len > 0 and prefix[0] < 128) {
                    const first: u8 = @intCast(prefix[0]);
                    var search_pos: usize = 0;
                    while (std.mem.indexOfScalar(u8, input[search_pos..], first)) |rel| {
                        const abs = search_pos + rel;
                        var res: vm.MatchResult = undefined;
                        if (try self.engine.nfa.matchAt(input, abs, &res)) {
                            defer res.deinit(self.allocator);
                            return try self.buildMatch(input, abs, res.end, res.captures);
                        }
                        search_pos = abs + 1;
                    }
                    return null;
                }
            }
        }

        return switch (self.engine) {
            .nfa => |*e| blk: {
                var search_pos: usize = 0;
                while (search_pos <= input.len) {
                    var res: vm.MatchResult = undefined;
                    if (try e.matchAt(input, search_pos, &res)) {
                        defer res.deinit(self.allocator);
                        break :blk try self.buildMatch(input, search_pos, res.end, res.captures);
                    }
                    if (search_pos >= input.len) break;
                    search_pos += (unicode.decodeUtf8(input[search_pos..]) catch break).len;
                }
                break :blk null;
            },
            .backtrack => |*e| if (try e.find(input)) |res| {
                var mut_res = res;
                defer mut_res.deinit(self.allocator);
                return try self.buildBacktrackMatch(input, res);
            } else null,
        };
    }

    fn buildMatch(self: *Matcher, input: []const u8, start: usize, end: usize, nfa_caps: []const vm.MatchResult.Capture) !Match {
        const captures = try self.allocator.alloc([]const u8, self.regex.capture_count);
        for (nfa_caps, 0..) |c, i| captures[i] = c.text;
        return Match{ .slice = input[start..end], .start = start, .end = end, .captures = captures };
    }

    fn buildBacktrackMatch(self: *Matcher, input: []const u8, res: backtrack.BacktrackMatch) !Match {
        const captures = try self.allocator.alloc([]const u8, self.regex.capture_count);
        for (res.captures, 0..) |c, i| captures[i] = if (c.matched) input[c.start..c.end] else "";
        return Match{ .slice = input[res.start..res.end], .start = res.start, .end = res.end, .captures = captures };
    }
};

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
    const match = (try self.find(input)) orelse return try allocator.dupe(u8, input);
    defer match.deinit(allocator);
    const expanded = try expandReplacement(allocator, replacement, match.captures, match.slice);
    defer allocator.free(expanded);
    return try std.mem.concat(allocator, u8, &[_][]const u8{ input[0..match.start], expanded, input[match.end..] });
}

fn replaceAllImpl(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
    const matches = try self.findAll(allocator, input);
    defer {
        for (matches) |m| m.deinit(allocator);
        allocator.free(matches);
    }
    if (matches.len == 0) return try allocator.dupe(u8, input);
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var last: usize = 0;
    for (matches) |m| {
        try result.appendSlice(allocator, input[last..m.start]);
        const expanded = try expandReplacement(allocator, replacement, m.captures, m.slice);
        defer allocator.free(expanded);
        try result.appendSlice(allocator, expanded);
        last = m.end;
    }
    try result.appendSlice(allocator, input[last..]);
    return result.toOwnedSlice(allocator);
}

fn findAllImpl(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match {
    var list: std.ArrayList(Match) = .empty;
    defer list.deinit(allocator);
    var iter = self.iterator(input);
    defer iter.deinit();
    while (try iter.next(allocator)) |m| try list.append(allocator, m);
    return list.toOwnedSlice(allocator);
}

fn splitImpl(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    const matches = try self.findAll(allocator, input);
    defer {
        for (matches) |m| m.deinit(allocator);
        allocator.free(matches);
    }
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var last: usize = 0;
    for (matches) |m| {
        try parts.append(allocator, input[last..m.start]);
        last = m.end;
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

fn expandReplacement(allocator: std.mem.Allocator, replacement: []const u8, captures: []const []const u8, match_slice: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

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
                    try result.appendSlice(allocator, captures[group_idx - 1]);
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
    return result.toOwnedSlice(allocator);
}
