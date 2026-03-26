const std = @import("std");
const common = @import("common.zig");

/// Abstract Syntax Tree node types for regular expressions
pub const NodeType = enum {
    /// Matches a single literal character
    literal,
    /// Matches any character (.)
    any,
    /// Concatenation of two expressions
    concat,
    /// Alternation (|)
    alternation,
    /// Kleene star (*)
    star,
    /// Plus (+)
    plus,
    /// Optional (?)
    optional,
    /// Repetition {m,n}
    repeat,
    /// Character class [...]
    char_class,
    /// Capture group (...)
    group,
    /// Anchor (^, $, \b, \B)
    anchor,
    /// Empty/epsilon
    empty,
    /// Lookahead assertion (?=...) or (?!...)
    lookahead,
    /// Lookbehind assertion (?<=...) or (?<!...)
    lookbehind,
    atomic_group,
    conditional,
    backref,
    /// Extended grapheme cluster (\X)
    extended_grapheme,
    /// Recursive pattern (?R), (?0), (?1), etc.
    recursion,
};

/// Anchor types
pub const AnchorType = enum {
    start_line, // ^
    end_line, // $
    start_text, // \A
    end_text, // \z or \Z
    word_boundary, // \b
    non_word_boundary, // \B
};

/// Repetition bounds for {m,n}
pub const RepeatBounds = struct {
    min: usize,
    max: ?usize, // null means unbounded

    pub fn init(min: usize, max: ?usize) RepeatBounds {
        return .{ .min = min, .max = max };
    }

    pub fn exactly(n: usize) RepeatBounds {
        return .{ .min = n, .max = n };
    }

    pub fn atLeast(n: usize) RepeatBounds {
        return .{ .min = n, .max = null };
    }

    pub fn between(min: usize, max: usize) RepeatBounds {
        return .{ .min = min, .max = max };
    }
};

/// AST Node
pub const Node = struct {
    node_type: NodeType,
    data: NodeData,
    span: common.Span,

    pub const NodeData = union(NodeType) {
        literal: struct { c: common.Char, ignore_case: bool },
        any: struct { dot_all: bool },
        concat: Concat,
        alternation: Alternation,
        star: Quantifier,
        plus: Quantifier,
        optional: Quantifier,
        repeat: Repeat,
        char_class: struct { class: common.CharClass, ignore_case: bool },
        group: Group,
        anchor: struct { type: AnchorType, multiline: bool },
        empty: void,
        lookahead: Assertion,
        lookbehind: Assertion,
        atomic_group: struct { child: *Node },
        conditional: Conditional,
        backref: Backreference,
        extended_grapheme: void,
        recursion: RecursionTarget,
    };

    pub const Concat = struct {
        left: *Node,
        right: *Node,
    };

    pub const Alternation = struct {
        left: *Node,
        right: *Node,
    };

    pub const QuantifierMode = enum {
        greedy, // * + ? {n,m}
        lazy, // *? +? ?? {n,m}?
        possessive, // *+ ++ ?+ {n,m}+
    };

    pub const Quantifier = struct {
        child: *Node,
        mode: QuantifierMode = .greedy,
    };

    pub const Repeat = struct {
        child: *Node,
        bounds: RepeatBounds,
        mode: QuantifierMode = .greedy,
    };

    pub const Group = struct {
        child: *Node,
        capture_index: ?usize, // null for non-capturing groups
        name: ?[]const u8 = null, // null for unnamed groups
    };

    pub const Assertion = struct {
        child: *Node,
        positive: bool, // true for positive, false for negative
    };

    pub const Conditional = struct {
        condition: ConditionType,
        yes_branch: *Node,
        no_branch: ?*Node,
    };

    pub const ConditionType = union(enum) {
        group_number: usize,
        group_name: []const u8,
        assertion: *Node,
    };

    pub const Backreference = struct {
        index: usize, // 1-based capture group index
        name: ?[]const u8 = null, // optional name for named backreferences
    };

    /// Recursion target for (?R), (?0), (?1), etc.
    pub const RecursionTarget = struct {
        kind: union(enum) {
            whole_pattern, // (?R) or (?0) - recurse entire pattern
            group_number: usize, // (?1), (?2), etc. - recurse specific group
            // Future: group_name: []const u8, // (?&name) - recurse named group
        },
        keep_groups: ?[]const usize = null,
    };

    pub fn createRecursion(allocator: std.mem.Allocator, recursion: RecursionTarget, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .recursion,
            .data = .{ .recursion = recursion },
            .span = span,
        };
        return node;
    }

    pub fn createAny(allocator: std.mem.Allocator, dot_all: bool, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .any,
            .data = .{ .any = .{ .dot_all = dot_all } },
            .span = span,
        };
        return node;
    }

    /// Create an extended grapheme cluster node (\X)
    pub fn createExtendedGrapheme(allocator: std.mem.Allocator, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .extended_grapheme,
            .data = .{ .extended_grapheme = {} },
            .span = span,
        };
        return node;
    }

    pub fn createConcat(allocator: std.mem.Allocator, left: *Node, right: *Node, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .concat,
            .data = .{ .concat = .{ .left = left, .right = right } },
            .span = span,
        };
        return node;
    }

    pub fn createAlternation(allocator: std.mem.Allocator, left: *Node, right: *Node, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .alternation,
            .data = .{ .alternation = .{ .left = left, .right = right } },
            .span = span,
        };
        return node;
    }

    pub fn createStar(allocator: std.mem.Allocator, child: *Node, mode: QuantifierMode, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .star,
            .data = .{ .star = .{ .child = child, .mode = mode } },
            .span = span,
        };
        return node;
    }

    pub fn createPlus(allocator: std.mem.Allocator, child: *Node, mode: QuantifierMode, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .plus,
            .data = .{ .plus = .{ .child = child, .mode = mode } },
            .span = span,
        };
        return node;
    }

    pub fn createOptional(allocator: std.mem.Allocator, child: *Node, mode: QuantifierMode, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .optional,
            .data = .{ .optional = .{ .child = child, .mode = mode } },
            .span = span,
        };
        return node;
    }

    pub fn createRepeat(allocator: std.mem.Allocator, child: *Node, bounds: RepeatBounds, mode: QuantifierMode, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .repeat,
            .data = .{ .repeat = .{ .child = child, .bounds = bounds, .mode = mode } },
            .span = span,
        };
        return node;
    }

    pub fn createCharClass(allocator: std.mem.Allocator, char_class: common.CharClass, ignore_case: bool, span: common.Span) !*Node {
        // CRITICAL: Ensure fast_ascii bitset is initialized for Backtracking engine
        // The Backtracker operates directly on AST, not NFA, so we need precomputed bitset here
        var cc = char_class;
        cc.precompute();

        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .char_class,
            .data = .{ .char_class = .{ .class = cc, .ignore_case = ignore_case } },
            .span = span,
        };
        return node;
    }

    pub fn createGroup(allocator: std.mem.Allocator, child: *Node, capture_index: ?usize, span: common.Span) !*Node {
        return createNamedGroup(allocator, child, capture_index, null, span);
    }

    pub fn createNamedGroup(allocator: std.mem.Allocator, child: *Node, capture_index: ?usize, name: ?[]const u8, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .group,
            .data = .{ .group = .{ .child = child, .capture_index = capture_index, .name = name } },
            .span = span,
        };
        return node;
    }

    pub fn createAnchor(allocator: std.mem.Allocator, anchor_type: AnchorType, multiline: bool, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .anchor,
            .data = .{ .anchor = .{ .type = anchor_type, .multiline = multiline } },
            .span = span,
        };
        return node;
    }

    pub fn createEmpty(allocator: std.mem.Allocator, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .empty,
            .data = .{ .empty = {} },
            .span = span,
        };
        return node;
    }

    pub fn createLookahead(allocator: std.mem.Allocator, child: *Node, positive: bool, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .lookahead,
            .data = .{ .lookahead = .{ .child = child, .positive = positive } },
            .span = span,
        };
        return node;
    }

    pub fn createLookbehind(allocator: std.mem.Allocator, child: *Node, positive: bool, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .lookbehind,
            .data = .{ .lookbehind = .{ .child = child, .positive = positive } },
            .span = span,
        };
        return node;
    }

    pub fn createAtomicGroup(allocator: std.mem.Allocator, child: *Node, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .atomic_group,
            .data = .{ .atomic_group = .{ .child = child } },
            .span = span,
        };
        return node;
    }

    pub fn createConditional(allocator: std.mem.Allocator, condition: ConditionType, yes_branch: *Node, no_branch: ?*Node, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .conditional,
            .data = .{ .conditional = .{ .condition = condition, .yes_branch = yes_branch, .no_branch = no_branch } },
            .span = span,
        };
        return node;
    }

    pub fn createBackreference(allocator: std.mem.Allocator, index: usize, name: ?[]const u8, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .backref,
            .data = .{ .backref = .{ .index = index, .name = name } },
            .span = span,
        };
        return node;
    }

    /// Create a literal character node
    pub fn createLiteral(allocator: std.mem.Allocator, c: common.Char, ignore_case: bool, span: common.Span) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .node_type = .literal,
            .data = .{ .literal = .{ .c = c, .ignore_case = ignore_case } },
            .span = span,
        };
        return node;
    }
};

/// AST represents the entire parsed regular expression
pub const AST = struct {
    root: *Node,
    arena: std.heap.ArenaAllocator,
    capture_count: usize,

    pub fn init(arena: std.heap.ArenaAllocator, root: *Node, capture_count: usize) AST {
        return .{
            .root = root,
            .arena = arena,
            .capture_count = capture_count,
        };
    }

    pub fn deinit(self: *AST) void {
        self.arena.deinit();
    }
};

test "create literal node" {
    const allocator = std.testing.allocator;
    const span = common.Span.init(0, 1);
    const node = try Node.createLiteral(allocator, 'a', false, span);
    defer allocator.destroy(node);

    try std.testing.expectEqual(NodeType.literal, node.node_type);
    try std.testing.expectEqual(@as(common.Char, 'a'), node.data.literal.c);
    try std.testing.expectEqual(false, node.data.literal.ignore_case);
}

test "create concat node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span = common.Span.init(0, 2);

    const left = try Node.createLiteral(allocator, 'a', false, common.Span.init(0, 1));
    const right = try Node.createLiteral(allocator, 'b', false, common.Span.init(1, 2));
    const concat = try Node.createConcat(allocator, left, right, span);

    try std.testing.expectEqual(NodeType.concat, concat.node_type);
}

test "create star node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const span = common.Span.init(0, 2);

    const child = try Node.createLiteral(allocator, 'a', false, common.Span.init(0, 1));
    const star = try Node.createStar(allocator, child, .greedy, span);

    try std.testing.expectEqual(NodeType.star, star.node_type);
    try std.testing.expectEqual(true, star.data.star.mode == .greedy);
}

test "repeat bounds" {
    const exactly_3 = RepeatBounds.exactly(3);
    try std.testing.expectEqual(@as(usize, 3), exactly_3.min);
    try std.testing.expectEqual(@as(usize, 3), exactly_3.max.?);

    const at_least_2 = RepeatBounds.atLeast(2);
    try std.testing.expectEqual(@as(usize, 2), at_least_2.min);
    try std.testing.expectEqual(@as(?usize, null), at_least_2.max);

    const between_1_5 = RepeatBounds.between(1, 5);
    try std.testing.expectEqual(@as(usize, 1), between_1_5.min);
    try std.testing.expectEqual(@as(usize, 5), between_1_5.max.?);
}
