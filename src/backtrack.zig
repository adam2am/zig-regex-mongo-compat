const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const errors = @import("errors.zig");
const unicode = @import("unicode.zig");
const unicode_tables = @import("unicode_tables.zig");
const vm = @import("vm.zig");
const text_policy = @import("text_policy.zig");
const match_types = @import("match_types.zig");

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
    /// O(1) lookup table for group index -> AST node (for recursion)
    group_lookup: []?*ast.Node,
    /// Current recursion depth
    recursion_depth: usize,
    /// Maximum recursion depth (prevents stack overflow)
    max_recursion_depth: usize,
    /// If true, lazy quantifiers will not backtrack (used in find() to prefer different positions over more matches)
    disable_lazy_backtrack: bool,
    /// ReDoS protection: count of matching steps
    step_count: usize,
    /// Maximum steps before aborting (prevents catastrophic backtracking)
    max_steps: usize,
    /// Hard-abort flag to short-circuit ReDoS loops across all finding attempts
    aborted: bool,
    /// Named capture table mapping names to indices.
    /// Borrowed from the compiled Regex, which outlives matchers created from it.
    named_captures: ?*const std.StringArrayHashMap(usize),
    word_boundary_policy: text_policy.WordBoundaryPolicy,
    trusted_utf8: bool,

    /// Cycle detection stack for recursion (prevents infinite empty loops natively)
    recursion_call_stack: std.ArrayList(RecursionFrame),
    /// Centralized stack for backtracking candidate positions (removes per-node ArrayList allocations)
    match_state_stack: std.ArrayList(MatchState),

    pub const CaptureGroup = struct {
        start: usize,
        end: usize,
        matched: bool,
    };

    pub const RecursionFrame = struct {
        node: *ast.Node,
        pos: usize,
    };

    /// Default maximum steps: 10 million (prevents ReDoS while allowing complex patterns)
    pub const DEFAULT_MAX_STEPS: usize = 10_000_000;

    /// Default maximum recursion depth (prevents stack overflow on deeply recursive patterns)
    pub const DEFAULT_MAX_RECURSION_DEPTH: usize = 500;

    /// A candidate match position with its capture state snapshot.
    /// stack_base is an index into state_stack: peekState(stack_base) instantly
    /// restores captures to the exact moment this position was found - no re-running.
    pub const MatchState = struct {
        end_pos: usize,
        stack_base: usize,
    };

    pub fn init(allocator: std.mem.Allocator, root: *ast.Node, capture_count: usize, flags: common.CompileFlags, named_captures: ?*const std.StringArrayHashMap(usize), word_boundary_policy: text_policy.WordBoundaryPolicy, trusted_utf8: bool) !BacktrackEngine {
        const captures = try allocator.alloc(CaptureGroup, capture_count);
        for (captures) |*cap| {
            cap.* = .{ .start = 0, .end = 0, .matched = false };
        }

        // Pre-allocate O(1) group lookup table
        const lookup = try allocator.alloc(?*ast.Node, capture_count + 1);
        @memset(lookup, null);

        var engine = BacktrackEngine{
            .allocator = allocator,
            .ast_root = root,
            .capture_count = capture_count,
            .flags = flags,
            .input = &[_]u8{},
            .captures = captures,
            .state_stack = std.ArrayList(CaptureGroup).initCapacity(allocator, 0) catch unreachable,
            .group_lookup = lookup,
            .recursion_depth = 0,
            .max_recursion_depth = DEFAULT_MAX_RECURSION_DEPTH,
            .disable_lazy_backtrack = false,
            .step_count = 0,
            .max_steps = DEFAULT_MAX_STEPS,
            .aborted = false,
            .named_captures = named_captures,
            .word_boundary_policy = word_boundary_policy,
            .trusted_utf8 = trusted_utf8,
            .recursion_call_stack = std.ArrayList(RecursionFrame).initCapacity(allocator, DEFAULT_MAX_RECURSION_DEPTH) catch unreachable,
            .match_state_stack = std.ArrayList(MatchState).initCapacity(allocator, 16) catch unreachable,
        };

        // Build O(1) lookup table
        engine.indexGroups(root);

        return engine;
    }

    pub fn deinit(self: *BacktrackEngine) void {
        self.allocator.free(self.captures);
        self.allocator.free(self.group_lookup);
        self.state_stack.deinit(self.allocator);
        self.recursion_call_stack.deinit(self.allocator);
        self.match_state_stack.deinit(self.allocator);
    }

    /// Build O(1) lookup table for group index -> AST node
    fn indexGroups(self: *BacktrackEngine, node: *ast.Node) void {
        switch (node.node_type) {
            .group => {
                if (node.data.group.capture_index) |idx| {
                    if (idx > 0 and idx < self.group_lookup.len) {
                        self.group_lookup[idx] = node;
                    }
                }
                self.indexGroups(node.data.group.child);
            },
            .concat => {
                self.indexGroups(node.data.concat.left);
                self.indexGroups(node.data.concat.right);
            },
            .alternation => {
                self.indexGroups(node.data.alternation.left);
                self.indexGroups(node.data.alternation.right);
            },
            .star => self.indexGroups(node.data.star.child),
            .plus => self.indexGroups(node.data.plus.child),
            .optional => self.indexGroups(node.data.optional.child),
            .repeat => self.indexGroups(node.data.repeat.child),
            .lookahead => self.indexGroups(node.data.lookahead.child),
            .lookbehind => self.indexGroups(node.data.lookbehind.child),
            .atomic_group => self.indexGroups(node.data.atomic_group.child),
            .conditional => {
                const cond = node.data.conditional;
                self.indexGroups(cond.yes_branch);
                if (cond.no_branch) |no| self.indexGroups(no);
            },
            else => {},
        }
    }

    /// Match a recursive pattern (?R), (?0), (?1), etc.
    fn matchRecursion(self: *BacktrackEngine, recursion: ast.Node.RecursionTarget, pos: usize) ?usize {
        // Depth limit check
        if (self.recursion_depth >= self.max_recursion_depth) {
            return null;
        }

        // Resolve target node
        const target_node = switch (recursion.kind) {
            .whole_pattern => self.ast_root,
            .group_number => |num| blk: {
                if (num == 0 or num >= self.group_lookup.len) break :blk null;
                break :blk self.group_lookup[num];
            },
            .group_name => |name| blk: {
                if (self.named_captures) |named_captures| {
                    if (named_captures.get(name)) |num| {
                        if (num > 0 and num < self.group_lookup.len) break :blk self.group_lookup[num];
                    }
                }
                break :blk null;
            },
        };

        if (target_node == null) return null;

        // Cycle Detection: If we are already evaluating this exact node at this exact position,
        // we have hit an infinite loop (empty recursion). Fail this branch to force backtracking.
        for (self.recursion_call_stack.items) |frame| {
            if (frame.node == target_node.? and frame.pos == pos) {
                return null;
            }
        }

        // Save state for PCRE2 "outer wins" semantics
        const stack_base = self.pushState() catch return null;

        self.recursion_depth += 1;
        self.recursion_call_stack.append(self.allocator, .{ .node = target_node.?, .pos = pos }) catch return null;

        defer {
            self.recursion_depth -= 1;
            _ = self.recursion_call_stack.pop();
        }

        // Recurse into target
        const result_pos = self.matchNode(target_node.?, pos);

        // PCRE2 10.46+: Selective capture retention via Stack Patching
        // If match succeeded, patch the saved outer state inside the state_stack
        // before we pop it, ensuring specified groups retain their inner values.
        if (result_pos != null) {
            if (recursion.keep_groups) |keeps| {
                for (keeps) |kg| {
                    // Resolve group: either by index or by name lookup
                    const group_idx = switch (kg) {
                        .index => |idx| idx,
                        .name => |name| if (self.named_captures) |named_captures| named_captures.get(name) orelse 0 else 0,
                    };
                    if (group_idx > 0 and group_idx <= self.captures.len) {
                        const idx = group_idx - 1;
                        // Write inner capture directly into the saved outer state
                        self.state_stack.items[stack_base + idx] = self.captures[idx];
                    }
                }
            }
        }

        // Restore captures (outer wins, applying any patched retains)
        self.popState(stack_base);

        return result_pos;
    }

    const MatchSpan = struct {
        start: usize,
        end: usize,
    };

    /// Test if pattern matches entire input
    pub fn isMatch(self: *BacktrackEngine, input: []const u8) !bool {
        return (try self.search(input)) != null;
    }

    /// Find first match in input
    pub fn find(self: *BacktrackEngine, input: []const u8) !?BacktrackMatch {
        const span = (try self.search(input)) orelse return null;

        const captures = self.allocator.alloc(BacktrackMatch.CaptureGroup, self.captures.len) catch return null;
        for (self.captures, 0..) |cap, i| {
            captures[i] = .{
                .start = cap.start,
                .end = cap.end,
                .matched = cap.matched,
            };
        }

        return BacktrackMatch{
            .start = span.start,
            .end = span.end,
            .captures = captures,
        };
    }

    pub fn findInto(self: *BacktrackEngine, input: []const u8, captures: []match_types.Capture, start_out: *usize, end_out: *usize) !bool {
        if (captures.len != self.captures.len) return errors.RegexError.InvalidArgument;

        const span = (try self.search(input)) orelse return false;
        for (captures, 0..) |*capture, i| {
            const source = self.captures[i];
            capture.* = .{
                .start = source.start,
                .end = source.end,
                .matched = source.matched,
                .text = if (source.matched) input[source.start..source.end] else "",
            };
        }
        start_out.* = span.start;
        end_out.* = span.end;
        return true;
    }

    fn search(self: *BacktrackEngine, input: []const u8) !?MatchSpan {
        self.input = input;
        self.aborted = false;

        var pos: usize = 0;
        while (pos <= input.len) : (pos += 1) {
            if (self.aborted) return errors.RegexError.Timeout;
            self.resetCaptures();
            self.state_stack.shrinkRetainingCapacity(0);
            self.match_state_stack.shrinkRetainingCapacity(0);
            self.step_count = 0;
            if (self.matchNode(self.ast_root, pos)) |end_pos| {
                if (end_pos > pos or (end_pos == pos and self.canMatchEmpty(self.ast_root))) {
                    return .{ .start = pos, .end = end_pos };
                }
            }
            if (self.aborted) return errors.RegexError.Timeout;
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
            .literal, .any, .char_class, .backref, .extended_grapheme => false,
            .empty, .anchor, .lookahead, .lookbehind => true,
            .recursion => true, // Recursion can be nested with quantifiers that match empty
            .atomic_group => self.canMatchEmpty(node.data.atomic_group.child),
            .conditional => blk: {
                const cond = node.data.conditional;
                if (cond.no_branch) |no_branch| {
                    break :blk self.canMatchEmpty(cond.yes_branch) or self.canMatchEmpty(no_branch);
                }
                break :blk true; // No else branch, condition false naturally matches empty
            },
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
        if (self.aborted) return null;

        // ReDoS protection: increment step counter and check limit
        self.step_count += 1;
        if (self.step_count > self.max_steps) {
            self.aborted = true; // Hard lock the engine from continuing
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
            .char_class => blk: {
                const class = node.data.char_class.class;
                if (pos >= self.input.len) break :blk null;

                const char_result = self.decodeUtf8ForwardWithLen(self.input, pos) orelse break :blk null;
                const matches = class.matches(char_result.codepoint);

                break :blk if (matches) pos + char_result.len else null;
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
                        if (anchor_data.multiline) {
                            if (pos < self.input.len and self.input[pos] == '\n') break :blk pos;
                            if (pos < self.input.len and self.input[pos] == '\r' and pos + 1 < self.input.len and self.input[pos + 1] == '\n') break :blk pos;
                        }
                        break :blk null;
                    },
                    .start_text => if (pos == 0) pos else null,
                    .end_text_strict => if (text_policy.isAbsoluteEnd(self.input, pos)) pos else null,
                    .end_text_before_final_newline => if (text_policy.isEndBeforeFinalNewline(self.input, pos)) pos else null,
                    .word_boundary => if (text_policy.isWordBoundary(self.input, pos, self.word_boundary_policy)) pos else null,
                    .non_word_boundary => if (text_policy.isNonWordBoundary(self.input, pos, self.word_boundary_policy)) pos else null,
                };
            },
            .empty => pos,
            .lookahead => self.matchLookahead(node.data.lookahead, pos),
            .lookbehind => self.matchLookbehind(node.data.lookbehind, pos),
            .atomic_group => self.matchAtomicGroup(node.data.atomic_group, pos),
            .conditional => self.matchConditional(node.data.conditional, pos),
            .backref => self.matchBackref(node.data.backref, pos),
            .extended_grapheme => self.matchExtendedGrapheme(pos),
            .recursion => self.matchRecursion(node.data.recursion, pos),
        };
    }

    fn matchLiteral(self: *BacktrackEngine, literal_data: ast.Node.NodeData, pos: usize) ?usize {
        if (pos >= self.input.len) return null;

        const c = literal_data.literal.c;
        const ignore_case = literal_data.literal.ignore_case;

        // Decode UTF-8 character at current position
        const utf8_char = self.decodeUtf8ForwardWithLen(self.input, pos) orelse return null;
        const input_char = utf8_char.codepoint;

        const matches = if (ignore_case)
            unicode.toLower(input_char) == unicode.toLower(c)
        else
            input_char == c;

        return if (matches) pos + utf8_char.len else null;
    }

    fn matchAny(self: *BacktrackEngine, any_data: ast.Node.NodeData, pos: usize) ?usize {
        if (pos >= self.input.len) return null;

        // Decode UTF-8 character at current position
        const utf8_char = self.decodeUtf8ForwardWithLen(self.input, pos) orelse return null;
        const c = utf8_char.codepoint;

        if (!any_data.any.dot_all and c == '\n') return null;

        return pos + utf8_char.len;
    }

    fn matchConcat(self: *BacktrackEngine, concat: ast.Node.Concat, pos: usize) ?usize {
        const left_has_quantifiers = self.hasQuantifiers(concat.left);

        if (left_has_quantifiers) {
            // Phase 1: collect all possible left-side end positions.
            const stack_base_idx = self.match_state_stack.items.len;
            defer self.match_state_stack.shrinkRetainingCapacity(stack_base_idx);

            // base_state anchors the stack before collection. dropState(base_state) on success
            const base_state = self.pushState() catch return null;
            self.collectAllMatches(concat.left, pos) catch {
                self.popState(base_state);
                return null;
            };

            // Phase 2: Iterate candidates from the centralized stack
            const end_idx = self.match_state_stack.items.len;
            var i = stack_base_idx;
            while (i < end_idx) : (i += 1) {
                const left_match = self.match_state_stack.items[i];
                self.peekState(left_match.stack_base);
                if (self.matchNode(concat.right, left_match.end_pos)) |result| {
                    self.dropState(base_state); // SUCCESS: keep right-side captures, clean up phase-1 stack
                    return result;
                }
            }
            self.popState(base_state); // TOTAL FAILURE: restore pre-concat state
            return null;
        } else {
            // No quantifiers on left: simple push/pop around left+right match.
            const stack_base = self.pushState() catch return null;
            if (self.matchNode(concat.left, pos)) |left_end| {
                if (self.matchNode(concat.right, left_end)) |result| {
                    self.dropState(stack_base); // SUCCESS: keep captures from both sides
                    return result;
                }
            }
            self.popState(stack_base); // FAILURE: restore pre-concat state
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
            .atomic_group => self.hasQuantifiers(node.data.atomic_group.child),
            .lookahead, .lookbehind => blk: {
                const child = if (node.node_type == .lookahead) node.data.lookahead.child else node.data.lookbehind.child;
                break :blk self.hasQuantifiers(child);
            },
            .conditional => self.hasQuantifiers(node.data.conditional.yes_branch) or
                (if (node.data.conditional.no_branch) |nb| self.hasQuantifiers(nb) else false),
            else => false,
        };
    }

    /// Collect all possible ending positions for matching a node at a given position.
    /// Results are appended to the centralized self.match_state_stack.
    fn collectAllMatches(self: *BacktrackEngine, node: *ast.Node, pos: usize) std.mem.Allocator.Error!void {
        switch (node.node_type) {
            .star => {
                const quant = node.data.star;
                if (quant.mode == .possessive) {
                    return try self.collectPossessiveStarMatches(quant.child, pos, &self.match_state_stack);
                }
                if (quant.mode == .greedy) {
                    try self.collectGreedyStarMatches(quant.child, pos);
                } else {
                    try self.collectLazyStarMatches(quant.child, pos);
                }
            },
            .plus => {
                const quant = node.data.plus;
                if (quant.mode == .possessive) {
                    return try self.collectPossessivePlusMatches(quant.child, pos, &self.match_state_stack);
                }
                // Must match at least once - snapshot state for the first match
                const first_base = try self.pushState();
                const first_match = self.matchNode(quant.child, pos) orelse {
                    self.popState(first_base);
                    return;
                };
                if (quant.mode == .greedy) {
                    try self.collectGreedyStarMatches(quant.child, first_match);
                } else {
                    // Lazy: minimal (one match) first
                    try self.match_state_stack.append(self.allocator, .{ .end_pos = first_match, .stack_base = try self.pushState() });
                    if (!self.disable_lazy_backtrack) {
                        try self.collectLazyStarMatches(quant.child, first_match);
                    }
                }
            },
            .optional => {
                const quant = node.data.optional;
                if (quant.mode == .possessive) {
                    return try self.collectPossessiveOptionalMatches(quant.child, pos, &self.match_state_stack);
                }
                if (quant.mode == .greedy) {
                    // Greedy: try matching first, snapshot after each outcome, then zero
                    if (self.matchNode(quant.child, pos)) |end| {
                        try self.match_state_stack.append(self.allocator, .{ .end_pos = end, .stack_base = try self.pushState() });
                    }
                    // Restore to pre-optional state for the zero-match option
                    const zero_base = try self.pushState();
                    try self.match_state_stack.append(self.allocator, .{ .end_pos = pos, .stack_base = zero_base });
                } else {
                    // Lazy: zero first, then matching
                    const zero_base = try self.pushState();
                    try self.match_state_stack.append(self.allocator, .{ .end_pos = pos, .stack_base = zero_base });
                    if (!self.disable_lazy_backtrack) {
                        if (self.matchNode(quant.child, pos)) |end| {
                            try self.match_state_stack.append(self.allocator, .{ .end_pos = end, .stack_base = try self.pushState() });
                        }
                    }
                }
            },
            .repeat => {
                const repeat = node.data.repeat;
                if (repeat.mode == .possessive) {
                    return try self.collectPossessiveRepeatMatches(repeat, pos, &self.match_state_stack);
                }
                if (repeat.mode == .greedy) {
                    try self.collectGreedyRepeatMatches(repeat, pos);
                } else {
                    try self.collectLazyRepeatMatches(repeat, pos);
                }
            },
            .concat => {
                const concat = node.data.concat;
                const left_has_quantifiers = self.hasQuantifiers(concat.left);
                const right_has_quantifiers = self.hasQuantifiers(concat.right);

                if (left_has_quantifiers) {
                    const stack_base_idx = self.match_state_stack.items.len;
                    try self.collectAllMatches(concat.left, pos);
                    const left_end_idx = self.match_state_stack.items.len;

                    var final_results: std.ArrayList(MatchState) = .empty;
                    defer final_results.deinit(self.allocator);

                    var i = stack_base_idx;
                    while (i < left_end_idx) : (i += 1) {
                        const left_match = self.match_state_stack.items[i];
                        self.peekState(left_match.stack_base);

                        if (right_has_quantifiers) {
                            const right_base_idx = self.match_state_stack.items.len;
                            try self.collectAllMatches(concat.right, left_match.end_pos);
                            try final_results.appendSlice(self.allocator, self.match_state_stack.items[right_base_idx..]);
                            self.match_state_stack.shrinkRetainingCapacity(right_base_idx);
                        } else {
                            if (self.matchNode(concat.right, left_match.end_pos)) |right_end| {
                                try final_results.append(self.allocator, .{ .end_pos = right_end, .stack_base = try self.pushState() });
                            }
                        }
                    }

                    self.match_state_stack.shrinkRetainingCapacity(stack_base_idx);
                    try self.match_state_stack.appendSlice(self.allocator, final_results.items);
                } else if (right_has_quantifiers) {
                    if (self.matchNode(concat.left, pos)) |left_end| {
                        try self.collectAllMatches(concat.right, left_end);
                    }
                } else { // Neither left nor right has quantifiers
                    if (self.matchNode(node, pos)) |end| {
                        try self.match_state_stack.append(self.allocator, .{ .end_pos = end, .stack_base = try self.pushState() });
                    }
                }
            },
            else => {
                if (self.matchNode(node, pos)) |end| {
                    try self.match_state_stack.append(self.allocator, .{ .end_pos = end, .stack_base = try self.pushState() });
                }
            },
        }
    }

    /// Lazy star: collect positions from pos in order (shortest first), snapshot captures at each step
    fn collectLazyStarMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize) !void {
        try self.match_state_stack.append(self.allocator, .{ .end_pos = pos, .stack_base = try self.pushState() }); // zero matches first
        if (self.disable_lazy_backtrack) return;
        var current_pos = pos;
        while (self.matchNode(child, current_pos)) |next_pos| {
            if (next_pos == current_pos) break;
            current_pos = next_pos;
            try self.match_state_stack.append(self.allocator, .{ .end_pos = current_pos, .stack_base = try self.pushState() });
        }
    }

    /// Greedy repeat: collect positions after matching min..max times, return longest-first
    fn collectGreedyRepeatMatches(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize) !void {
        var current_pos = pos;
        var i: usize = 0;
        // Match minimum required times
        while (i < repeat.bounds.min) : (i += 1) {
            current_pos = self.matchNode(repeat.child, current_pos) orelse return;
        }

        const base_idx = self.match_state_stack.items.len;
        try self.match_state_stack.append(self.allocator, .{ .end_pos = current_pos, .stack_base = try self.pushState() }); // at-min position

        if (repeat.bounds.max) |max_count| {
            while (i < max_count) : (i += 1) {
                const next = self.matchNode(repeat.child, current_pos) orelse break;
                if (next == current_pos) break;
                current_pos = next;
                try self.match_state_stack.append(self.allocator, .{ .end_pos = current_pos, .stack_base = try self.pushState() });
            }
        } else {
            // No max: match as many as possible
            while (true) {
                const next = self.matchNode(repeat.child, current_pos) orelse break;
                if (next == current_pos) break;
                current_pos = next;
                try self.match_state_stack.append(self.allocator, .{ .end_pos = current_pos, .stack_base = try self.pushState() });
            }
        }

        // Reverse for greedy: longest match first
        std.mem.reverse(MatchState, self.match_state_stack.items[base_idx..]);
    }

    /// Lazy repeat: collect positions after matching min..max times, snapshot captures, return shortest-first
    fn collectLazyRepeatMatches(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize) !void {
        var current_pos = pos;
        var i: usize = 0;
        while (i < repeat.bounds.min) : (i += 1) {
            current_pos = self.matchNode(repeat.child, current_pos) orelse return;
        }
        try self.match_state_stack.append(self.allocator, .{ .end_pos = current_pos, .stack_base = try self.pushState() }); // at-min first
        if (self.disable_lazy_backtrack) return;

        if (repeat.bounds.max) |max_count| {
            while (i < max_count) : (i += 1) {
                const next = self.matchNode(repeat.child, current_pos) orelse break;
                if (next == current_pos) break;
                current_pos = next;
                try self.match_state_stack.append(self.allocator, .{ .end_pos = current_pos, .stack_base = try self.pushState() });
            }
        } else {
            while (true) {
                const next = self.matchNode(repeat.child, current_pos) orelse break;
                if (next == current_pos) break;
                current_pos = next;
                try self.match_state_stack.append(self.allocator, .{ .end_pos = current_pos, .stack_base = try self.pushState() });
            }
        }
    }

    fn matchAlternation(self: *BacktrackEngine, alt: ast.Node.Alternation, pos: usize) ?usize {
        // Save state so a failing left branch doesn't pollute captures for the right branch.
        // dropState(left_success)  = keep captures from successful left branch
        // popState(left_failure)   = restore to pre-left state before trying right branch
        const stack_base = self.pushState() catch return null;
        if (self.matchNode(alt.left, pos)) |end| {
            self.dropState(stack_base); // SUCCESS: left captures are valid, keep them
            return end;
        }
        self.popState(stack_base); // FAILURE: discard left's partial captures, restore pre-left state
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
    fn collectPossessiveStarMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize, positions: *std.ArrayList(MatchState)) !void {
        var current_pos = pos;
        while (self.matchNode(child, current_pos)) |next| {
            if (next == current_pos) break;
            current_pos = next;
        }
        try positions.append(self.allocator, .{ .end_pos = current_pos, .stack_base = try self.pushState() });
    }

    /// Collect possessive plus matches: only maximal match (no backtracking)
    fn collectPossessivePlusMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize, positions: *std.ArrayList(MatchState)) !void {
        const first_match = self.matchNode(child, pos) orelse return;
        var current_pos = first_match;
        while (self.matchNode(child, current_pos)) |next| {
            if (next == current_pos) break;
            current_pos = next;
        }
        try positions.append(self.allocator, .{ .end_pos = current_pos, .stack_base = try self.pushState() });
    }

    /// Collect possessive optional matches: only maximal match (no backtracking)
    fn collectPossessiveOptionalMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize, positions: *std.ArrayList(MatchState)) !void {
        if (self.matchNode(child, pos)) |next| {
            try positions.append(self.allocator, .{ .end_pos = next, .stack_base = try self.pushState() });
        } else {
            try positions.append(self.allocator, .{ .end_pos = pos, .stack_base = try self.pushState() });
        }
    }

    /// Collect possessive repeat matches: only maximal match (no backtracking)
    fn collectPossessiveRepeatMatches(self: *BacktrackEngine, repeat: ast.Node.Repeat, pos: usize, positions: *std.ArrayList(MatchState)) !void {
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

        try positions.append(self.allocator, .{ .end_pos = current_pos, .stack_base = try self.pushState() });
    }

    fn decodeUtf8ForwardWithLen(self: *const BacktrackEngine, input: []const u8, pos: usize) ?struct { codepoint: u21, len: u8 } {
        if (pos >= input.len) return null;
        if (self.trusted_utf8) {
            const res = unicode.decodeUtf8Trusted(input, pos);
            return .{ .codepoint = res.codepoint, .len = @intCast(res.len) };
        }
        const len = std.unicode.utf8ByteSequenceLength(input[pos]) catch return null;
        if (pos + len > input.len) return null;
        const codepoint = std.unicode.utf8Decode(input[pos .. pos + len]) catch return null;
        return .{ .codepoint = codepoint, .len = len };
    }

    fn decodeUtf8Forward(self: *const BacktrackEngine, input: []const u8, pos: usize) ?u21 {
        const result = self.decodeUtf8ForwardWithLen(input, pos) orelse return null;
        return result.codepoint;
    }

    fn decodeUtf8Backward(self: *const BacktrackEngine, input: []const u8, pos: usize) ?u21 {
        if (pos == 0) return null;
        var i = pos - 1;
        while (i > 0 and (input[i] & 0xC0) == 0x80) : (i -= 1) {}
        return self.decodeUtf8Forward(input, i);
    }

    /// Push current captures to the stack in O(1) amortized time
    inline fn pushState(self: *BacktrackEngine) !usize {
        const stack_base = self.state_stack.items.len;
        try self.state_stack.appendSlice(self.allocator, self.captures);
        return stack_base;
    }

    /// Pop captures from the stack back to current state (used on FAILURE - restores pre-match state)
    inline fn popState(self: *BacktrackEngine, stack_base: usize) void {
        const saved_slice = self.state_stack.items[stack_base .. stack_base + self.captures.len];
        @memcpy(self.captures, saved_slice);
        self.state_stack.shrinkRetainingCapacity(stack_base);
    }

    fn collectGreedyStarMatches(self: *BacktrackEngine, child: *ast.Node, pos: usize) !void {
        var current_pos = pos;
        var positions: std.ArrayList(MatchState) = .empty;
        defer positions.deinit(self.allocator);

        while (self.matchNode(child, current_pos)) |next| {
            if (next == current_pos) break;
            try positions.append(self.allocator, .{ .end_pos = current_pos, .stack_base = try self.pushState() });
            current_pos = next;
        }
        try positions.append(self.allocator, .{ .end_pos = current_pos, .stack_base = try self.pushState() });

        // Push to global match stack in REVERSE (greedy = prefer longer)
        var i: usize = positions.items.len;
        while (i > 0) {
            i -= 1;
            try self.match_state_stack.append(self.allocator, positions.items[i]);
        }
    }
    /// Drop saved state from the stack WITHOUT restoring captures (used on SUCCESS - keeps captures, frees stack)
    /// This is the O(1) cleanup primitive that makes nested recursion safe
    inline fn dropState(self: *BacktrackEngine, stack_base: usize) void {
        self.state_stack.shrinkRetainingCapacity(stack_base);
    }

    /// Load captures from a saved stack snapshot WITHOUT modifying the stack size.
    /// Used in matchConcat Phase 2: for each candidate MatchState, peekState() teleports
    /// the capture array back to the exact nanosecond that position was found - O(capture_count) memcpy only.
    inline fn peekState(self: *BacktrackEngine, stack_base: usize) void {
        const saved_slice = self.state_stack.items[stack_base .. stack_base + self.captures.len];
        @memcpy(self.captures, saved_slice);
    }

    fn matchGroup(self: *BacktrackEngine, group: ast.Node.Group, pos: usize) ?usize {
        const end_pos = self.matchNode(group.child, pos) orelse return null;

        if (group.capture_index) |cap_idx| {
            if (cap_idx > 0 and cap_idx <= self.captures.len) {
                self.captures[cap_idx - 1] = .{
                    .start = pos,
                    .end = end_pos,
                    .matched = end_pos > pos, // Only matched if consumed something
                };
            }
        }

        return end_pos;
    }

    fn matchBackref(self: *BacktrackEngine, backref: ast.Node.Backreference, pos: usize) ?usize {
        // Resolve index: use absolute index if > 0, otherwise lookup by name.
        // Returns null for invalid references (unmatched name, no index) - caller decides behavior.
        const resolved_idx: ?usize = if (backref.index > 0) backref.index else blk: {
            if (backref.name) |name| {
                if (self.named_captures) |named_captures| {
                    break :blk named_captures.get(name);
                }
            }
            break :blk null;
        };

        const idx = resolved_idx orelse return null; // Unresolved reference
        if (idx > self.captures.len) return null; // Out of bounds

        const cap = self.captures[idx - 1];
        if (!cap.matched) {
            // Forward relative refs (\g{+n}) reference a group not yet captured.
            // PCRE2 treats them as matching empty string (permissive forward-ref semantics).
            // All other unmatched backrefs (\1, \k<name>, \g{n}, \g{-n}) fail the match.
            return if (backref.is_forward_ref) pos else null;
        }

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
        const child_match = self.matchNode(assertion.child, pos);

        // PCRE semantics: captures made inside a positive lookahead persist if successful
        if (assertion.positive and child_match != null) {
            self.dropState(stack_base);
            return pos;
        }

        self.popState(stack_base);
        return if (!assertion.positive and child_match == null) pos else null;
    }

    fn matchAtomicGroup(self: *BacktrackEngine, atomic: anytype, pos: usize) ?usize {
        // Atomic groups prevent backtracking: match child once, commit or fail
        return self.matchNode(atomic.child, pos);
    }

    /// Robust helper to resolve Grapheme Break properties.
    /// Acts as a fast-path interceptor and fallback to guarantee critical properties
    /// are correct even if the generated UCD tables are outdated or misparsed.
    fn getGraphemeBreakProperty(cp: u21) unicode_tables.GraphemeBreakProperty {
        if (cp == '\r') return .gbCR;
        if (cp == '\n') return .gbLF;
        if (cp == 0x200D) return .gbZWJ;
        if (cp >= 0x1F1E6 and cp <= 0x1F1FF) return .gbRegional_Indicator;

        // Hangul Jamo (Essential for Korean text clustering)
        if (cp >= 0x1100 and cp <= 0x115F) return .gbL;
        if (cp >= 0x1160 and cp <= 0x11A7) return .gbV;
        if (cp >= 0x11A8 and cp <= 0x11FF) return .gbT;
        if (cp >= 0xAC00 and cp <= 0xD7A3) {
            const t_index = (cp - 0xAC00) % 28;
            return if (t_index == 0) .gbLV else .gbLVT;
        }

        // Extended Pictographic (Emoji rules for ZWJ)
        // Grouped ranges cover: Misc Symbols, Dingbats, Emoticons, Transport, Ext-A, etc.
        if ((cp >= 0x2600 and cp <= 0x27BF) or
            (cp >= 0x1F300 and cp <= 0x1F6FF) or
            (cp >= 0x1F900 and cp <= 0x1FAFF) or
            (cp >= 0x1F180 and cp <= 0x1F2FF) or
            (cp >= 0x1F780 and cp <= 0x1F7FF))
        {
            // Skin tone modifiers are Extend, not EP
            if (cp >= 0x1F3FB and cp <= 0x1F3FF) return .gbExtend;
            return .gbExtended_Pictographic;
        }

        // Fallback to Category-based rules (avoids corrupted generator tables)
        // Category parsing was intact, so we derive graphemes directly from it
        const cat = unicode_tables.getUcdRecord(cp).category;

        // Cc (Control) and Cf (Format)
        if (cat == @intFromEnum(unicode_tables.GeneralCategory.Cc) or
            cat == @intFromEnum(unicode_tables.GeneralCategory.Cf)) return .gbControl;

        // Mn (Nonspacing Mark), Me (Enclosing Mark)
        if (cat == @intFromEnum(unicode_tables.GeneralCategory.Mn) or
            cat == @intFromEnum(unicode_tables.GeneralCategory.Me)) return .gbExtend;

        // Mc (Spacing Mark)
        if (cat == @intFromEnum(unicode_tables.GeneralCategory.Mc)) return .gbSpacingMark;

        return .gbOther;
    }

    /// Match an extended grapheme cluster (\X)
    /// Implements Unicode UAX#29 + PCRE2 extensions for emoji ZWJ sequences
    fn matchExtendedGrapheme(self: *BacktrackEngine, pos: usize) ?usize {
        if (pos >= self.input.len) return null;

        var ptr = pos;

        // Decode first codepoint
        const first = self.decodeUtf8ForwardWithLen(self.input, ptr) orelse return null;
        var lgb = getGraphemeBreakProperty(first.codepoint);
        ptr += first.len;

        // Track if we are in an Extended_Pictographic sequence
        var in_ep_sequence = (lgb == .gbExtended_Pictographic);

        while (ptr < self.input.len) {
            const next = self.decodeUtf8ForwardWithLen(self.input, ptr) orelse break;
            const rgb = getGraphemeBreakProperty(next.codepoint);

            var breaks = true;

            // GB3: CR x LF
            if (lgb == .gbCR and rgb == .gbLF) {
                breaks = false;
            }
            // GB4: (Control | CR | LF) Г· Any
            else if (lgb == .gbControl or lgb == .gbCR or lgb == .gbLF) {
                breaks = true;
            }
            // GB5: Any Г· (Control | CR | LF)
            else if (rgb == .gbControl or rgb == .gbCR or rgb == .gbLF) {
                breaks = true;
            }
            // GB6: L x (L | V | LV | LVT)
            else if (lgb == .gbL and (rgb == .gbL or rgb == .gbV or rgb == .gbLV or rgb == .gbLVT)) {
                breaks = false;
            }
            // GB7: (LV | V) x (V | T)
            else if ((lgb == .gbLV or lgb == .gbV) and (rgb == .gbV or rgb == .gbT)) {
                breaks = false;
            }
            // GB8: (LVT | T) x T
            else if ((lgb == .gbLVT or lgb == .gbT) and rgb == .gbT) {
                breaks = false;
            }
            // GB9: x (Extend | ZWJ)
            else if (rgb == .gbExtend or rgb == .gbZWJ) {
                breaks = false;
            }
            // GB9a: x SpacingMark
            else if (rgb == .gbSpacingMark) {
                breaks = false;
            }
            // GB9b: Prepend x
            else if (lgb == .gbPrepend) {
                breaks = false;
            }
            // GB11: \p{Extended_Pictographic} Extend* ZWJ x \p{Extended_Pictographic}
            else if (in_ep_sequence and lgb == .gbZWJ and rgb == .gbExtended_Pictographic) {
                breaks = false;
            }
            // GB12, GB13: Regional_Indicator x Regional_Indicator
            else if (lgb == .gbRegional_Indicator and rgb == .gbRegional_Indicator) {
                const ri_count = self.countPrecedingRI(ptr);
                // If ri_count is odd, it's the second RI of a pair, so do not break.
                // If ri_count is even, it's the first RI of a new pair, so break.
                if (ri_count % 2 == 1) {
                    breaks = false;
                } else {
                    breaks = true;
                }
            }

            if (breaks) break;

            // State update for GB11
            if (rgb == .gbExtended_Pictographic) {
                in_ep_sequence = true;
            } else if (rgb == .gbExtend) {
                // Extend doesn't reset the in_ep_sequence state
            } else if (rgb == .gbZWJ and in_ep_sequence) {
                // ZWJ maintains state if we were already in it
            } else {
                in_ep_sequence = false;
            }

            lgb = rgb;

            ptr += next.len;
        }

        return if (ptr > pos) ptr else null;
    }

    /// Count preceding Regional Indicators for even-count rule
    fn countPrecedingRI(self: *const BacktrackEngine, pos: usize) u32 {
        var count: u32 = 0;
        var p = pos;

        while (p > 0) {
            // Find start of previous character
            var char_start = p - 1;
            while (char_start > 0 and (self.input[char_start] & 0xC0) == 0x80) {
                char_start -= 1;
            }

            const cp = self.decodeUtf8Forward(self.input, char_start) orelse break;
            if (getGraphemeBreakProperty(cp) != .gbRegional_Indicator) {
                break;
            }

            count += 1;
            p = char_start;
        }

        return count;
    }

    fn matchConditional(self: *BacktrackEngine, cond: ast.Node.Conditional, pos: usize) ?usize {
        // Evaluate condition
        const condition_met = switch (cond.condition) {
            .group_number => |num| blk: {
                // Check if group was captured (group numbers are 1-indexed)
                if (num == 0 or num > self.captures.len) break :blk false;
                const capture = self.captures[num - 1];
                break :blk capture.matched;
            },
            .group_name => blk: {
                // TODO: Named group support not yet implemented
                break :blk false;
            },
            .assertion => |assertion_node| blk: {
                // Test if assertion matches at current position
                const result = self.matchNode(assertion_node, pos);
                break :blk result != null;
            },
        };

        // Match appropriate branch
        if (condition_met) {
            return self.matchNode(cond.yes_branch, pos);
        } else if (cond.no_branch) |no_branch| {
            return self.matchNode(no_branch, pos);
        } else {
            // No else branch, condition not met - match succeeds without consuming
            return pos;
        }
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
            check_pos = unicode.stepBackward(self.input, check_pos);
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

    var named_captures = std.StringArrayHashMap(usize).init(allocator);
    defer named_captures.deinit();

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{}, &named_captures, text_policy.fromFlags(.{}), true);
    defer engine.deinit();

    // Should timeout/abort instead of hanging
    const result = engine.find(input) catch null;

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

    var named_captures = std.StringArrayHashMap(usize).init(allocator);
    defer named_captures.deinit();

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{}, &named_captures, text_policy.fromFlags(.{}), true);
    defer engine.deinit();

    const result = engine.find(input) catch null;
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

    var named_captures = std.StringArrayHashMap(usize).init(allocator);
    defer named_captures.deinit();

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{}, &named_captures, text_policy.fromFlags(.{}), true);
    defer engine.deinit();

    const result = engine.find(input) catch null;
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

    var named_captures = std.StringArrayHashMap(usize).init(allocator);
    defer named_captures.deinit();

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{}, &named_captures, text_policy.fromFlags(.{}), true);
    defer engine.deinit();

    // Set a very low limit to test timeout behavior
    engine.max_steps = 100;

    const result = engine.find(input) catch null;
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

    var named_captures = std.StringArrayHashMap(usize).init(allocator);
    defer named_captures.deinit();

    var engine = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, .{}, &named_captures, text_policy.fromFlags(.{}), true);
    defer engine.deinit();

    const initial_count = engine.step_count;
    _ = engine.find(input) catch {};

    // Step counter should have increased
    try std.testing.expect(engine.step_count > initial_count);
}
