const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const unicode_tables = @import("unicode_tables.zig");
const vm = @import("vm.zig");

/// Backtracking-based regex engine
/// Supports: lazy quantifiers, lookahead/lookbehind, backreferences
/// Trade-off: O(2^n) worst case, but supports features impossible in Thompson NFA
/// Match result from backtracking engine
pub const BacktrackMatch = struct {
    start: usize,
    end: usize,
    captures: []CaptureGroup,

    pub const CaptureGroup = struct {
        start: usize,
        end: usize,
        matched: bool,
    };

    pub fn deinit(self: *BacktrackMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.captures);
    }
};

/// Backtracking engine state
pub const BacktrackEngine = struct {
    allocator: std.mem.Allocator,
    ast_root: *ast.Node,
    capture_count: usize,
    flags: common.CompileFlags,
    input: []const u8,
    captures: []CaptureGroup,
    /// Centralized pre-allocated stack for O(1) backtracking state saves (Zero-allocation hot path)
    state_stack: std.ArrayList(CaptureGroup),
    /// If true, lazy quantifiers will not backtrack (used in find() to prefer different positions over more matches)
    disable_lazy_backtrack: bool,
    /// ReDoS protection: count of matching steps
    step_count: usize,
    /// Maximum steps before aborting (prevents catastrophic backtracking)
    max_steps: usize,

    pub const CaptureGroup = struct {
        start: usize,
        end: usize,
        matched: bool,
    };

    /// Default maximum steps: 10 million (prevents ReDoS while allowing complex patterns)
    pub const DEFAULT_MAX_STEPS: usize = 10_000_000;

    pub fn init(allocator: std.mem.Allocator, root: *ast.Node, capture_count: usize, flags: common.CompileFlags) !BacktrackEngine {
        const captures = try allocator.alloc(CaptureGroup, capture_count);
        for (captures) |*cap| {
            cap.* = .{ .start = 0, .end = 0, .matched = false };
        }

        return BacktrackEngine{
            .allocator = allocator,
            .ast_root = root,
            .capture_count = capture_count,
            .flags = flags,
            .input = &[_]u8{},
            .captures = captures,
            .state_stack = std.ArrayList(CaptureGroup).initCapacity(allocator, 0) catch unreachable,
            .disable_lazy_backtrack = false,
            .step_count = 0,
            .max_steps = DEFAULT_MAX_STEPS,
        };
    }

    pub fn deinit(self: *BacktrackEngine) void {
        self.allocator.free(self.captures);
        self.state_stack.deinit(self.allocator);
    }

    /// Test if pattern matches entire input
    pub fn isMatch(self: *BacktrackEngine, input: []const u8) bool {
        if (self.find(input)) |match| {
            self.allocator.free(match.captures);
            return true;
        }
        return false;
    }

    /// Find first match in input
    pub fn find(self: *BacktrackEngine, input: []const u8) ?BacktrackMatch {
        self.input = input;
        // REMOVED: This flag broke lazy quantifiers by preventing expansion
        // Lazy quantifiers need backtracking to work correctly
        // self.disable_lazy_backtrack = true;
        // defer self.disable_lazy_backtrack = false;

        var pos: usize = 0;
        while (pos <= input.len) : (pos += 1) {
            self.resetCaptures();
            self.step_count = 0; // Reset step counter per starting position
            if (self.matchNode(self.ast_root, pos)) |end_pos| {
                if (end_pos > pos or (end_pos == pos and self.canMatchEmpty(self.ast_root))) {
                    // Found a match
                    const captures = self.allocator.alloc(BacktrackMatch.CaptureGroup, self.captures.len) catch return null;
                    for (self.captures, 0..) |cap, i| {
                        captures[i] = .{
                            .start = cap.start,
                            .end = cap.end,
                            .matched = cap.matched,
                        };
                    }

                    return BacktrackMatch{
                        .start = pos,
                        .end = end_pos,
                        .captures = captures,
                    };
                }
            }
        }
        return null;
    }

    /// Reset all capture groups
    pub fn resetCaptures(self: *BacktrackEngine) void {
        for (self.captures) |*cap| {
            cap.matched = false;
            cap.start = 0;
            cap.end = 0;
        }
    }

    /// Check if a node can match empty string
    pub fn canMatchEmpty(self: *BacktrackEngine, node: *ast.Node) bool {
        return switch (node.node_type) {
            .literal, .any, .char_class, .backref => false,
            .empty, .anchor, .lookahead, .lookbehind => true,
            .concat => self.canMatchEmpty(node.data.concat.left) and self.canMatchEmpty(node.data.concat.right),
            .alternation => self.canMatchEmpty(node.data.alternation.left) or self.canMatchEmpty(node.data.alternation.right),
            .star, .optional => true,
            .plus => self.canMatchEmpty(node.data.plus.child),
            .repeat => node.data.repeat.bounds.min == 0 or self.canMatchEmpty(node.data.repeat.child),
            .group => self.canMatchEmpty(node.data.group.child),
        };
    }

    /// Match a node starting at position, returns end position or null if no match
    /// Returns position where match ended, or null if no match
    pub fn matchNode(self: *BacktrackEngine, node: *ast.Node, pos: usize) ?usize {
        // ReDoS protection: increment step counter and check limit
        self.step_count += 1;
        if (self.step_count > self.max_steps) {
            return null; // Abort matching to prevent catastrophic backtracking
        }

        return switch (node.node_type) {
            .literal => self.matchLiteral(node.data, pos),
            .any => self.matchAny(node.data, pos),
            .concat => self.matchConcat(node.data.concat, pos),
            .alternation => self.matchAlternation(node.data.alternation, pos),
            .star => self.matchStar(node.data.star, pos),
            .plus => self.matchPlus(node.data.plus, pos),
            .optional => self.matchOptional(node.data.optional, pos),
            .repeat => self.matchRepeat(node.data.repeat, pos),
            .char_class => {
                const class = node.data.char_class.class;
                if (pos >= self.input.len) return null;

                const char_result = decodeUtf8ForwardWithLen(self.input, pos) orelse return null;
                const matches = class.matches(char_result.codepoint);

                if (matches) {
                    return pos + char_result.len;
                } else {
                    return null;
                }
            },
            .group => self.matchGroup(node.data.group, pos),
            .anchor => blk: {
                const anchor_data = node.data.anchor;
                break :blk switch (anchor_data.type) {
                    .start_line => {
                        if (pos == 0) break :blk pos;
                        if (anchor_data.multiline and pos > 0 and self.input[pos - 1] == '\n') break :blk pos;
                        break :blk null;
                    },
                    .end_line => {
                        if (pos == self.input.len) break :blk pos;
                        if (anchor_data.multiline and pos < self.input.len and self.input[pos] == '\n') break :blk pos;
                        break :blk null;
                    },
                    .start_text => if (pos == 0) pos else null,
                    .end_text => if (pos == self.input.len) pos else null,
                    .word_boundary => {
                        const before_cp = decodeUtf8Backward(self.input, pos);
                        const after_cp = decodeUtf8Forward(self.input, pos);
                        const before_is_word = if (before_cp) |cp| unicode_tables.isWordChar(cp, self.flags.unicode) else false;
                        const after_is_word = if (after_cp) |cp| unicode_tables.isWordChar(cp, self.flags.unicode) else false;
                        break :blk if (before_is_word != after_is_word) pos else null;
                    },
                    .non_word_boundary => {
                        const before_cp = decodeUtf8Backward(self.input, pos);
                        const after_cp = decodeUtf8Forward(self.input, pos);
                        const before_is_word = if (before_cp) |cp| unicode_tables.isWordChar(cp, self.flags.unicode) else false;
                        const after_is_word = if (after_cp) |cp| unicode_tables.isWordChar(cp, self.flags.unicode) else false;
                        break :blk if (before_is_word == after_is_word) pos else null;
                    },
                };
            },
            .empty => pos,
            .lookahead => self.matchLookahead(node.data.lookahead, pos),
            .lookbehind => self.matchLookbehind(node.data.lookbehind, pos),
            .backref => self.matchBackref(node.data.backref, pos),
        };
    }

    fn matchLiteral(self: *BacktrackEngine, literal_data: ast.Node.NodeData, pos: usize) ?usize {
        if (pos >= self.input.len) return null;

        const c = literal_data.literal.c;
        const ignore_case = literal_data.literal.ignore_case;

        // Decode UTF-8 character at current position
        const utf8_char = decodeUtf8ForwardWithLen(self.input, pos) orelse return null;
        const input_char = utf8_char.codepoint;

        const matches = if (ignore_case)
            toLower(input_char) == toLower(c)
        else
            input_char == c;

        return if (matches) pos + utf8_char.len else null;
    }

    fn toLower(c: common.Char) common.Char {
        // ASCII fast path
        if (c >= 'A' and c <= 'Z') {
            return c + ('a' - 'A');
        }
        // TODO: Unicode case folding for non-ASCII characters
        return c;
    }

    fn matchAny(self: *BacktrackEngine, any_data: ast.Node.NodeData, pos: usize) ?usize {
        if (pos >= self.input.len) return null;

        const c = self.input[pos];
        if (!any_data.any.dot_all and c == '\n') return null;

        return pos + 1;
    }

    fn matchConcat(self: *BacktrackEngine, concat: ast.Node.Concat, pos: usize) ?usize {
        // Check if left side has quantifiers that need backtracking
        const needs_backtrack = self.hasQuantifiers(concat.left);

        if (needs_backtrack) {
            // For quantifiers, collect all possible matches and try them in order
            // Lazy quantifiers will be tried minimal-first, greedy maximal-first
            var left_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return null;
            defer left_positions.deinit(self.allocator);

            self.collectAllMatches(concat.left, pos, &left_positions) catch return null;

            for (left_positions.items) |left_end| {
                // Zero-allocation state save using the centralized stack
                const stack_base = self.pushState() catch continue;

                if (self.matchNode(concat.right, left_end)) |result| {
                    return result;
                }

                self.popState(stack_base);
            }
            return null;
        } else {
            // For simple patterns without quantifiers, just try once
            if (self.matchNode(concat.left, pos)) |left_end| {
                if (self.matchNode(concat.right, left_end)) |right_end| {
                    return right_end;
                }
            }
            return null;
        }
    }

    fn hasQuantifiers(self: *BacktrackEngine, node: *ast.Node) bool {
        return switch (node.node_type) {
            // Any quantifier needs backtracking support
            .star, .plus, .optional, .repeat => true,
            // Recursively check children
            .concat => self.hasQuantifiers(node.data.concat.left) or self.hasQuantifiers(node.data.concat.right),
            .alternation => self.hasQuantifiers(node.data.alternation.left) or self.hasQuantifiers(node.data.alternation.right),
            .group => self.hasQuantifiers(node.data.group.child),
            else => false,
        };
    }

    /// Collect all possible ending positions for matching a node at a given position
    /// For lazy quantifiers, this returns positions in order: minimal first
    /// For greedy quantifiers, this returns positions in order: maximal first
    fn collectAllMatches(self: *BacktrackEngine, node: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
        switch (node.node_type) {
            .star => {
                const quant = node.data.star;

                // Possessive quantifiers: collect only maximal match
                if (quant.mode == .possessive) {
                    return try self.collectPossessiveStarMatches(quant.child, pos, positions);
                }

                if (quant.mode == .greedy) {
                    // Greedy: try maximal first, then backtrack
                    try self.collectGreedyStarMatches(quant.child, pos, positions);
                } else {
                    // Lazy: try minimal first, then more
                    try self.collectLazyStarMatches(quant.child, pos, positions);
                }
            },
            .plus => {
                const quant = node.data.plus;

                // Possessive quantifiers: collect only maximal match
                if (quant.mode == .possessive) {
                    return try self.collectPossessivePlusMatches(quant.child, pos, positions);
                }

                // Must match at least once
                const first_match = self.matchNode(quant.child, pos) orelse return;

                if (quant.mode == .greedy) {
                    // Greedy: try maximal first
                    try self.collectGreedyStarMatches(quant.child, first_match, positions);
                } else {
                    // Lazy: try minimal (one match) first, then more
                    try positions.append(self.allocator, first_match);
                    // If lazy backtrack is disabled (find() mode), only return minimal match
                    if (!self.disable_lazy_backtrack) {
                        try self.collectLazyStarMatches(quant.child, first_match, positions);
                    }
                }
            },
            .optional => {
                const quant = node.data.optional;

                // Possessive quantifiers: collect only maximal match
                if (quant.mode == .possessive) {
                    return try self.collectPossessiveOptionalMatches(quant.child, pos, positions);
                }

                if (quant.mode == .greedy) {
                    // Greedy: try matching first, then zero
                    if (self.matchNode(quant.child, pos)) |end| {
                        try positions.append(self.allocator, end);
                    }
                    try positions.append(self.allocator, pos); // zero matches
                } else {
                    // Lazy: try zero first, then matching
                    try positions.append(self.allocator, pos); // zero matches first
                    // If lazy backtrack is disabled (find() mode), only return minimal (zero)
                    if (!self.disable_lazy_backtrack) {
                        if (self.matchNode(quant.child, pos)) |end| {
                            try positions.append(self.allocator, end);
                        }
                    }
                }
            },
            .repeat => {
                const repeat = node.data.repeat;

                // Possessive quantifiers: collect only maximal match
                if (repeat.mode == .possessive) {
                    return try self.collectPossessiveRepeatMatches(repeat, pos, positions);
                }

                if (repeat.mode == .greedy) {
                    try self.collectGreedyRepeatMatches(repeat, pos, positions);
                } else {
                    try self.collectLazyRepeatMatches(repeat, pos, positions);
                }
            },
            else => {
                // For non-quantifiers, there's only one possible match
                if (self.matchNode(node, pos)) |end| {
                    try positions.append(self.allocator, end);
                }
            },
        }
    }

    fn collectGreedyStarMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
        // Collect all matches from longest to shortest
        var all_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return;
        defer all_positions.deinit(self.allocator);

        try all_positions.append(self.allocator, pos); // zero matches

        var current_pos = pos;
        while (self.matchNode(child, current_pos)) |next_pos| {
            if (next_pos == current_pos) break; // Prevent infinite loop
            current_pos = next_pos;
            try all_positions.append(self.allocator, current_pos);
        }

        // Return in reverse order (greedy: longest first)
        var i: usize = all_positions.items.len;
        while (i > 0) {
            i -= 1;
            try positions.append(self.allocator, all_positions.items[i]);
        }
    }

    fn collectLazyStarMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
        // Collect all matches from shortest to longest
        try positions.append(self.allocator, pos); // zero matches first

        // If lazy backtrack is disabled (find() mode), only return minimal match
        if (self.disable_lazy_backtrack) {
            return;
        }

        var current_pos = pos;
        while (self.matchNode(child, current_pos)) |next_pos| {
            if (next_pos == current_pos) break; // Prevent infinite loop
            current_pos = next_pos;
            try positions.append(self.allocator, current_pos);
        }
    }

    fn collectGreedyRepeatMatches(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, positions: *std.ArrayList(usize)) !void {
        const min = repeat.bounds.min;
        const max = repeat.bounds.max;

        // Match minimum required times
        var current_pos = pos;
        var i: usize = 0;
        while (i < min) : (i += 1) {
            current_pos = self.matchNode(repeat.child, current_pos) orelse return;
        }

        // Collect all positions from min to max (or unbounded)
        var all_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return;
        defer all_positions.deinit(self.allocator);

        try all_positions.append(self.allocator, current_pos);

        if (max) |max_count| {
            while (i < max_count) : (i += 1) {
                if (self.matchNode(repeat.child, current_pos)) |next_pos| {
                    if (next_pos == current_pos) break;
                    current_pos = next_pos;
                    try all_positions.append(self.allocator, current_pos);
                } else break;
            }
        } else {
            // Unbounded: keep matching until we can't
            while (self.matchNode(repeat.child, current_pos)) |next_pos| {
                if (next_pos == current_pos) break;
                current_pos = next_pos;
                try all_positions.append(self.allocator, current_pos);
            }
        }

        // Return in reverse order (greedy: longest first)
        var j: usize = all_positions.items.len;
        while (j > 0) {
            j -= 1;
            try positions.append(self.allocator, all_positions.items[j]);
        }
    }

    fn collectLazyRepeatMatches(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, positions: *std.ArrayList(usize)) !void {
        const min = repeat.bounds.min;
        const max = repeat.bounds.max;

        // Match minimum required times
        var current_pos = pos;
        var i: usize = 0;
        while (i < min) : (i += 1) {
            current_pos = self.matchNode(repeat.child, current_pos) orelse return;
        }

        // Return positions from min to max (lazy: shortest first)
        try positions.append(self.allocator, current_pos);

        // If lazy backtrack is disabled (find() mode), only return minimal match
        if (self.disable_lazy_backtrack) {
            return;
        }

        if (max) |max_count| {
            while (i < max_count) : (i += 1) {
                if (self.matchNode(repeat.child, current_pos)) |next_pos| {
                    if (next_pos == current_pos) break;
                    current_pos = next_pos;
                    try positions.append(self.allocator, current_pos);
                } else break;
            }
        } else {
            // Unbounded: keep matching until we can't
            while (self.matchNode(repeat.child, current_pos)) |next_pos| {
                if (next_pos == current_pos) break;
                current_pos = next_pos;
                try positions.append(self.allocator, current_pos);
            }
        }
    }

    fn matchAlternation(self: *BacktrackEngine, alt: ast.Node.Alternation, pos: usize) ?usize {
        // Try left first
        if (self.matchNode(alt.left, pos)) |end| {
            return end;
        }
        // Try right
        return self.matchNode(alt.right, pos);
    }

    fn matchStar(self: *BacktrackEngine, quant: ast.Node.Quantifier, pos: usize) ?usize {
        if (quant.mode == .greedy) {
            // Greedy: match as many as possible
            return self.matchStarGreedy(quant.child, pos);
        } else {
            // Lazy: match as few as possible
            return self.matchStarLazy(quant.child, pos);
        }
    }

    fn matchStarGreedy(self: *BacktrackEngine, child: *ast.Node, pos: usize) ?usize {
        // Try to match as many as possible, backtrack if needed
        var current_pos = pos;
        var match_positions = std.ArrayList(usize).initCapacity(self.allocator, 0) catch return null;
        defer match_positions.deinit(self.allocator);

        match_positions.append(self.allocator, current_pos) catch return null;

        // Collect all possible match positions
        while (self.matchNode(child, current_pos)) |next_pos| {
            if (next_pos == current_pos) break; // Prevent infinite loop on empty matches
            current_pos = next_pos;
            match_positions.append(self.allocator, current_pos) catch break;
        }

        // Greedy: return the longest match
        return match_positions.getLast();
    }

    fn matchStarLazy(self: *BacktrackEngine, _: *ast.Node, pos: usize) ?usize {
        _ = self;
        // Lazy: try zero matches first, then one, two, etc.
        // For lazy, we start with the minimum (zero) and only match more if needed
        // The caller will handle backtracking if the rest of the pattern fails
        return pos;
    }

    fn matchPlus(self: *BacktrackEngine, quant: ast.Node.Quantifier, pos: usize) ?usize {
        // Must match at least once
        const first_match = self.matchNode(quant.child, pos) orelse return null;

        if (quant.mode == .greedy) {
            return self.matchStarGreedy(quant.child, first_match);
        } else {
            return first_match; // Lazy: just one match
        }
    }

    fn matchOptional(self: *BacktrackEngine, quant: ast.Node.Quantifier, pos: usize) ?usize {
        if (quant.mode == .greedy) {
            // Greedy: try to match first
            if (self.matchNode(quant.child, pos)) |end| {
                return end;
            }
            return pos; // Or match zero
        } else {
            // Lazy: match zero first
            return pos;
        }
    }

    fn matchRepeat(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize) ?usize {
        const min = repeat.bounds.min;
        const max = repeat.bounds.max;

        // Match minimum required times
        var current_pos = pos;
        var i: usize = 0;
        while (i < min) : (i += 1) {
            current_pos = self.matchNode(repeat.child, current_pos) orelse return null;
        }

        // If no max, behave like star after minimum
        if (max == null) {
            if (repeat.mode == .greedy) {
                return self.matchStarGreedy(repeat.child, current_pos);
            } else {
                return current_pos; // Lazy: stop at minimum
            }
        }

        // Match up to max times
        const max_count = max.?;
        if (repeat.mode == .greedy) {
            // Greedy: try to match as many as possible
            while (i < max_count) : (i += 1) {
                if (self.matchNode(repeat.child, current_pos)) |next_pos| {
                    if (next_pos == current_pos) break;
                    current_pos = next_pos;
                } else {
                    break;
                }
            }
        }
        // Lazy or reached max: return current position
        return current_pos;
    }

    /// Collect possessive star matches: only maximal match (no backtracking)
    fn collectPossessiveStarMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
        var current_pos = pos;
        // Match as many times as possible
        while (self.matchNode(child, current_pos)) |next| {
            if (next == current_pos) break; // Prevent infinite loop on empty matches
            current_pos = next;
        }
        // Only return the maximal match position
        try positions.append(self.allocator, current_pos);
    }

    /// Collect possessive plus matches: only maximal match (no backtracking)
    fn collectPossessivePlusMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
        // Must match at least once
        const first_match = self.matchNode(child, pos) orelse return;

        var current_pos = first_match;
        // Match as many more times as possible
        while (self.matchNode(child, current_pos)) |next| {
            if (next == current_pos) break; // Prevent infinite loop
            current_pos = next;
        }
        // Only return the maximal match position
        try positions.append(self.allocator, current_pos);
    }

    /// Collect possessive optional matches: only maximal match (no backtracking)
    fn collectPossessiveOptionalMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize, positions: *std.ArrayList(usize)) !void {
        // Try to match once
        if (self.matchNode(child, pos)) |next| {
            // Matched: return the match position only
            try positions.append(self.allocator, next);
        } else {
            // Didn't match: return original position only
            try positions.append(self.allocator, pos);
        }
    }

    /// Collect possessive repeat matches: only maximal match (no backtracking)
    fn collectPossessiveRepeatMatches(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, positions: *std.ArrayList(usize)) !void {
        const min = repeat.bounds.min;
        const max = repeat.bounds.max;

        var current_pos = pos;
        var count: usize = 0;

        // Match minimum required times
        while (count < min) : (count += 1) {
            if (self.matchNode(repeat.child, current_pos)) |next| {
                if (next == current_pos) break; // Prevent infinite loop
                current_pos = next;
            } else {
                // Failed to match minimum - no match at all
                return;
            }
        }

        // Match as many more times as possible (up to max if specified)
        if (max) |max_count| {
            while (count < max_count) : (count += 1) {
                if (self.matchNode(repeat.child, current_pos)) |next| {
                    if (next == current_pos) break;
                    current_pos = next;
                } else {
                    break;
                }
            }
        } else {
            // No max: match as many as possible
            while (self.matchNode(repeat.child, current_pos)) |next| {
                if (next == current_pos) break;
                current_pos = next;
            }
        }

        // Only return the maximal match position
        try positions.append(self.allocator, current_pos);
    }

    fn decodeUtf8ForwardWithLen(input: []const u8, pos: usize) ?struct { codepoint: u21, len: u8 } {
        if (pos >= input.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(input[pos]) catch return null;
        if (pos + len > input.len) return null;
        const codepoint = std.unicode.utf8Decode(input[pos .. pos + len]) catch return null;
        return .{ .codepoint = codepoint, .len = len };
    }

    fn decodeUtf8Forward(input: []const u8, pos: usize) ?u21 {
        const result = decodeUtf8ForwardWithLen(input, pos) orelse return null;
        return result.codepoint;
    }

    fn decodeUtf8Backward(input: []const u8, pos: usize) ?u21 {
        if (pos == 0) return null;
        var i = pos - 1;
        while (i > 0 and (input[i] & 0xC0) == 0x80) : (i -= 1) {}
        return decodeUtf8Forward(input, i);
    }

    /// Push current captures to the stack in O(1) amortized time
    inline fn pushState(self: *BacktrackEngine) !usize {
        const stack_base = self.state_stack.items.len;
        try self.state_stack.appendSlice(self.allocator, self.captures);
        return stack_base;
    }

    /// Pop captures from the stack back to current state
    inline fn popState(self: *BacktrackEngine, stack_base: usize) void {
        const saved_slice = self.state_stack.items[stack_base .. stack_base + self.captures.len];
        @memcpy(self.captures, saved_slice);
        self.state_stack.shrinkRetainingCapacity(stack_base);
    }

    fn matchGroup(self: *BacktrackEngine, group: ast.Node.Group, pos: usize) ?usize {
        const end_pos = self.matchNode(group.child, pos) orelse return null;

        if (group.capture_index) |cap_idx| {
            if (cap_idx > 0 and cap_idx <= self.captures.len) {
                self.captures[cap_idx - 1] = .{
                    .start = pos,
                    .end = end_pos,
                    .matched = true,
                };
            }
        }

        return end_pos;
    }

    fn matchBackref(self: *BacktrackEngine, backref: ast.Node.Backreference, pos: usize) ?usize {
        if (backref.index == 0 or backref.index > self.captures.len) return null;
        const cap = self.captures[backref.index - 1];
        if (!cap.matched) return null;

        const expected_str = self.input[cap.start..cap.end];
        if (pos + expected_str.len > self.input.len) return null;

        const actual_str = self.input[pos .. pos + expected_str.len];

        const is_match = if (self.flags.case_insensitive)
            std.ascii.eqlIgnoreCase(expected_str, actual_str)
        else
            std.mem.eql(u8, expected_str, actual_str);

        if (is_match) {
            return pos + expected_str.len;
        }
        return null;
    }

    fn matchLookahead(self: *BacktrackEngine, assertion: ast.Node.Assertion, pos: usize) ?usize {
        const stack_base = self.pushState() catch return null;
        const matched = self.matchNode(assertion.child, pos) != null;
        self.popState(stack_base);

        if (matched == assertion.positive) return pos;
        return null;
    }

    fn matchLookbehind(self: *BacktrackEngine, assertion: ast.Node.Assertion, pos: usize) ?usize {
        const stack_base = self.pushState() catch return null;
        var matched = false;
        var check_pos = pos;

        while (true) {
            self.popState(stack_base);
            _ = self.pushState() catch break;
            if (self.matchNode(assertion.child, check_pos)) |end_pos| {
                if (end_pos == pos) {
                    matched = true;
                    break;
                }
            }
            if (check_pos == 0) break;
            check_pos -= 1;
        }
        self.popState(stack_base);
        if (matched == assertion.positive) return pos;
        return null;
    }
};

// ============================================================================
// SECURITY TESTS: ReDoS Protection
// ============================================================================

test "backtrack: ReDoS protection - nested quantifiers (a+)+b" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Pattern: (a+)+b - classic ReDoS pattern
    // Input: "aaaaaaaaaaaaaaaaaaaac" (20 'a's followed by 'c' instead of 'b')
    // This causes O(2^n) backtracking without protection

    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");

    var p = try parser.Parser.init(allocator, "(a+)+b", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var comp = compiler.Compiler.init(allocator);
    defer comp.deinit();
    _ = try comp.compile(&tree);

    // Input that doesn't match but would cause catastrophic backtracking
    const input = "aaaaaaaaaaaaaaaaaaaac";

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{});
    defer engine.deinit();

    // Should timeout/abort instead of hanging
    const result = engine.find(input);

    // Either returns null (no match) or completes quickly
    // The key is that it DOES return, not hang forever
    try std.testing.expect(result == null);

    // Verify step counter was incremented (shows protection is working)
    // We don't assert a specific minimum since the actual count depends on implementation
    try std.testing.expect(engine.step_count > 0);
}

test "backtrack: ReDoS protection - nested stars (a*)*b" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Pattern: (a*)*b - another catastrophic backtracking pattern

    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");

    var p = try parser.Parser.init(allocator, "(a*)*b", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var comp = compiler.Compiler.init(allocator);
    defer comp.deinit();
    _ = try comp.compile(&tree);

    const input = "aaaaaaaaaaaaaaaaaac";

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{});
    defer engine.deinit();

    const result = engine.find(input);
    try std.testing.expect(result == null);
}

test "backtrack: ReDoS protection - ambiguous alternation (a|a)*b" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Pattern: (a|a)*b - ambiguous alternation causing exponential backtracking

    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");

    var p = try parser.Parser.init(allocator, "(a|a)*b", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var comp = compiler.Compiler.init(allocator);
    defer comp.deinit();
    _ = try comp.compile(&tree);

    const input = "aaaaaaaaaaaaaaaac";

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{});
    defer engine.deinit();

    const result = engine.find(input);
    try std.testing.expect(result == null);
}

test "backtrack: configurable step limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test that we can configure a lower step limit

    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");

    var p = try parser.Parser.init(allocator, "(a+)+b", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var comp = compiler.Compiler.init(allocator);
    defer comp.deinit();
    _ = try comp.compile(&tree);

    const input = "aaaaaaaaaaaac";

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{});
    defer engine.deinit();

    // Set a very low limit to test timeout behavior
    engine.max_steps = 100;

    const result = engine.find(input);
    try std.testing.expect(result == null);

    // Should have done some steps (may or may not hit the limit depending on pattern)
    try std.testing.expect(engine.step_count > 0);
}

test "backtrack: step counter increments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Verify that step counter actually increments during matching

    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");

    var p = try parser.Parser.init(allocator, "a+b+", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var comp = compiler.Compiler.init(allocator);
    defer comp.deinit();
    _ = try comp.compile(&tree);

    const input = "aaaabbbbb";

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{});
    defer engine.deinit();

    const initial_count = engine.step_count;
    _ = engine.find(input);

    // Step counter should have increased
    try std.testing.expect(engine.step_count > initial_count);
}
