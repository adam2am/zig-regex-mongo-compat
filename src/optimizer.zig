const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");

/// Optimization information extracted from a pattern
pub const OptimizationInfo = struct {
    /// Literal prefix that must appear for the pattern to match
    /// This allows skipping ahead in the input using memchr/indexOf
    literal_prefix: ?[]const common.Char = null,

    /// Whether the pattern is anchored at start (^)
    anchored_start: bool = false,

    /// Whether the pattern is anchored at end ($)
    anchored_end: bool = false,

    /// Minimum length of any match
    min_length: usize = 0,

    /// Maximum length of any match (if bounded)
    max_length: ?usize = null,

    pub fn deinit(self: *OptimizationInfo, allocator: std.mem.Allocator) void {
        if (self.literal_prefix) |prefix| {
            allocator.free(prefix);
        }
    }
};

/// Optimizer that analyzes AST to extract optimization opportunities
pub const Optimizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Optimizer {
        return .{ .allocator = allocator };
    }

    /// Analyze AST and extract optimization information
    pub fn analyze(self: *Optimizer, root: *ast.Node) !OptimizationInfo {
        var info = OptimizationInfo{};

        // Check for anchors - traverse to leftmost/rightmost leaves
        var current_start = root;
        while (current_start.node_type == .concat) {
            current_start = current_start.data.concat.left;
        }
        if (current_start.node_type == .anchor and current_start.data.anchor.type == .start_line) {
            info.anchored_start = true;
        }

        var current_end = root;
        while (current_end.node_type == .concat) {
            current_end = current_end.data.concat.right;
        }
        if (current_end.node_type == .anchor and current_end.data.anchor.type == .end_line) {
            info.anchored_end = true;
        }

        // Extract literal prefix
        if (try self.extractLiteralPrefix(root)) |prefix| {
            info.literal_prefix = prefix;
        }

        // Calculate min/max lengths
        info.min_length = self.calculateMinLength(root);
        info.max_length = self.calculateMaxLength(root);

        return info;
    }

    /// Try to extract a literal prefix from the pattern
    /// Returns null if no useful prefix can be extracted
    fn extractLiteralPrefix(self: *Optimizer, node: *ast.Node) !?[]const common.Char {
        var prefix = try std.ArrayList(common.Char).initCapacity(self.allocator, 0);
        errdefer prefix.deinit(self.allocator);

        _ = try self.collectLiteralPrefix(node, &prefix);

        // Only useful if we got at least 2 characters
        if (prefix.items.len < 2) {
            prefix.deinit(self.allocator);
            return null;
        }

        return try prefix.toOwnedSlice(self.allocator);
    }

    /// Recursively collect literal characters from the start of the pattern
    fn collectLiteralPrefix(self: *Optimizer, node: *ast.Node, prefix: *std.ArrayList(common.Char)) !bool {
        return switch (node.node_type) {
            .literal => {
                try prefix.append(self.allocator, node.data.literal.c);
                return true;
            },
            .concat => {
                // For concatenation, try left side first
                const concat = node.data.concat;
                if (!try self.collectLiteralPrefix(concat.left, prefix)) {
                    return false;
                }
                // If left was successful and complete, try right
                return try self.collectLiteralPrefix(concat.right, prefix);
            },
            .group => {
                // For groups, recurse into child
                return try self.collectLiteralPrefix(node.data.group.child, prefix);
            },
            .anchor => {
                // Anchors don't affect prefix but don't stop collection
                return true;
            },
            // Any of these stop prefix collection
            .alternation, .star, .plus, .optional, .repeat, .any, .char_class, .backref, .extended_grapheme, .recursion => false,
            // Lookahead/lookbehind don't consume input, atomic groups do
            .lookahead, .lookbehind => true,
            .atomic_group => try self.collectLiteralPrefix(node.data.atomic_group.child, prefix),
            .conditional => false, // Cannot guarantee prefix for conditional nodes
            .empty => true,
        };
    }

    /// Calculate minimum possible match length
    fn calculateMinLength(self: *Optimizer, node: *ast.Node) usize {
        return switch (node.node_type) {
            .literal => 1,
            .any => 1,
            .char_class => 1,
            .extended_grapheme => 1,
            .recursion => 0, // Recursive pattern might match empty
            .anchor => 0,
            .empty => 0,
            .concat => self.calculateMinLength(node.data.concat.left) + self.calculateMinLength(node.data.concat.right),
            .alternation => @min(self.calculateMinLength(node.data.alternation.left), self.calculateMinLength(node.data.alternation.right)),
            .star, .optional => 0,
            .plus => self.calculateMinLength(node.data.plus.child),
            .repeat => node.data.repeat.bounds.min * self.calculateMinLength(node.data.repeat.child),
            .group => self.calculateMinLength(node.data.group.child),
            .lookahead, .lookbehind => 0,
            .atomic_group => self.calculateMinLength(node.data.atomic_group.child),
            .conditional => blk: {
                const cond = node.data.conditional;
                const yes_min = self.calculateMinLength(cond.yes_branch);
                const no_min = if (cond.no_branch) |no| self.calculateMinLength(no) else 0;
                break :blk @min(yes_min, no_min);
            },
            .backref => 0,
        };
    }

    /// Calculate maximum possible match length (if bounded)
    fn calculateMaxLength(self: *Optimizer, node: *ast.Node) ?usize {
        return switch (node.node_type) {
            .literal => 1,
            .any => 1,
            .char_class => 1,
            .extended_grapheme => null, // Grapheme clusters can be infinitely long (combining marks)
            .recursion => null, // Recursion can be unbounded
            .concat => {
                const left_max = self.calculateMaxLength(node.data.concat.left) orelse return null;
                const right_max = self.calculateMaxLength(node.data.concat.right) orelse return null;
                return left_max + right_max;
            },
            .alternation => {
                const left_max = self.calculateMaxLength(node.data.alternation.left);
                const right_max = self.calculateMaxLength(node.data.alternation.right);
                if (left_max == null or right_max == null) return null;
                return @max(left_max.?, right_max.?);
            },
            .star => null, // * means unbounded
            .optional => self.calculateMaxLength(node.data.optional.child), // ? matches 0 or 1 times
            .plus => null, // + means unbounded
            .repeat => {
                const repeat = node.data.repeat;
                if (repeat.bounds.max) |max| {
                    const child_max = self.calculateMaxLength(repeat.child) orelse return null;
                    return child_max * max;
                }
                return null;
            },
            .group => {
                return self.calculateMaxLength(node.data.group.child);
            },
            .lookahead, .lookbehind => {
                // Lookaround assertions don't consume input
                return 0;
            },
            .atomic_group => {
                return self.calculateMaxLength(node.data.atomic_group.child);
            },
            .conditional => blk: {
                const cond = node.data.conditional;
                const yes_max = self.calculateMaxLength(cond.yes_branch);
                const no_max = if (cond.no_branch) |no| self.calculateMaxLength(no) else 0;
                if (yes_max == null or no_max == null) break :blk null;
                break :blk @max(yes_max.?, no_max.?);
            },
            .backref => {
                // Backreferences have unbounded max length
                return null;
            },
            .anchor, .empty => 0,
        };
    }
};

test "optimizer: literal prefix extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Parser = @import("parser.zig").Parser;

    var parser = try Parser.init(allocator, "hello.*world", .{});
    var tree = try parser.parse();
    defer tree.deinit();

    var optimizer = Optimizer.init(allocator);
    var info = try optimizer.analyze(tree.root);
    defer info.deinit(allocator);

    try std.testing.expect(info.literal_prefix != null);
    if (info.literal_prefix) |prefix| {
        const expected_u21 = [_]u21{ 'h', 'e', 'l', 'l', 'o' };
        try std.testing.expectEqualSlices(u21, &expected_u21, prefix);
    }
}

test "optimizer: anchored detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Parser = @import("parser.zig").Parser;

    var parser = try Parser.init(allocator, "^hello$", .{});
    var tree = try parser.parse();
    defer tree.deinit();

    var optimizer = Optimizer.init(allocator);
    var info = try optimizer.analyze(tree.root);
    defer info.deinit(allocator);

    try std.testing.expect(info.anchored_start);
}

test "optimizer: min/max length calculation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Parser = @import("parser.zig").Parser;

    // Fixed length pattern
    var parser1 = try Parser.init(allocator, "hello", .{});
    var tree1 = try parser1.parse();
    defer tree1.deinit();

    var optimizer = Optimizer.init(allocator);
    var info1 = try optimizer.analyze(tree1.root);
    defer info1.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), info1.min_length);
    try std.testing.expectEqual(@as(?usize, 5), info1.max_length);

    // Variable length pattern
    var parser2 = try Parser.init(allocator, "a+", .{});
    var tree2 = try parser2.parse();
    defer tree2.deinit();

    var info2 = try optimizer.analyze(tree2.root);
    defer info2.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), info2.min_length);
    try std.testing.expectEqual(@as(?usize, null), info2.max_length);
}

test "optimizer: concat min/max length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Parser = @import("parser.zig").Parser;

    var parser = try Parser.init(allocator, "abc", .{});
    var tree = try parser.parse();
    defer tree.deinit();

    var optimizer = Optimizer.init(allocator);
    var info = try optimizer.analyze(tree.root);
    defer info.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), info.min_length);
    try std.testing.expectEqual(@as(?usize, 3), info.max_length);
}

test "optimizer: alternation min/max length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Parser = @import("parser.zig").Parser;

    var parser = try Parser.init(allocator, "a|bb", .{});
    var tree = try parser.parse();
    defer tree.deinit();

    var optimizer = Optimizer.init(allocator);
    var info = try optimizer.analyze(tree.root);
    defer info.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), info.min_length); // min of "a" (1) and "bb" (2)
    try std.testing.expectEqual(@as(?usize, 2), info.max_length); // max of "a" (1) and "bb" (2)
}

test "optimizer: star quantifier min/max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Parser = @import("parser.zig").Parser;

    var parser = try Parser.init(allocator, "a*", .{});
    var tree = try parser.parse();
    defer tree.deinit();

    var optimizer = Optimizer.init(allocator);
    var info = try optimizer.analyze(tree.root);
    defer info.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), info.min_length); // zero or more
    try std.testing.expectEqual(@as(?usize, null), info.max_length); // unbounded
}

test "optimizer: optional quantifier min/max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Parser = @import("parser.zig").Parser;

    var parser = try Parser.init(allocator, "a?", .{});
    var tree = try parser.parse();
    defer tree.deinit();

    var optimizer = Optimizer.init(allocator);
    var info = try optimizer.analyze(tree.root);
    defer info.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), info.min_length); // zero or one
    try std.testing.expectEqual(@as(?usize, 1), info.max_length);
}

test "optimizer: repeat quantifier min/max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Parser = @import("parser.zig").Parser;

    var parser = try Parser.init(allocator, "a{2,5}", .{});
    var tree = try parser.parse();
    defer tree.deinit();

    var optimizer = Optimizer.init(allocator);
    var info = try optimizer.analyze(tree.root);
    defer info.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), info.min_length);
    try std.testing.expectEqual(@as(?usize, 5), info.max_length);
}

test "optimizer: nested group with quantifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Parser = @import("parser.zig").Parser;

    var parser = try Parser.init(allocator, "(ab)+", .{});
    var tree = try parser.parse();
    defer tree.deinit();

    var optimizer = Optimizer.init(allocator);
    var info = try optimizer.analyze(tree.root);
    defer info.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), info.min_length); // at least one "ab"
    try std.testing.expectEqual(@as(?usize, null), info.max_length); // unbounded
}

test "optimizer: complex pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Parser = @import("parser.zig").Parser;

    var parser = try Parser.init(allocator, "a(b|cd)*e", .{});
    var tree = try parser.parse();
    defer tree.deinit();

    var optimizer = Optimizer.init(allocator);
    var info = try optimizer.analyze(tree.root);
    defer info.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), info.min_length); // "a" + "e" = 2
    try std.testing.expectEqual(@as(?usize, null), info.max_length); // unbounded due to *
}

test "optimizer: empty pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Parser = @import("parser.zig").Parser;

    var parser = try Parser.init(allocator, "", .{});
    var tree = try parser.parse();
    defer tree.deinit();

    var optimizer = Optimizer.init(allocator);
    var info = try optimizer.analyze(tree.root);
    defer info.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), info.min_length);
    try std.testing.expectEqual(@as(?usize, 0), info.max_length);
}
