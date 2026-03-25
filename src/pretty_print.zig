const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");

/// DRY helper: Convert anchor type to string representation
fn anchorToString(anchor_type: ast.AnchorType) []const u8 {
    return switch (anchor_type) {
        .start_line => "^",
        .end_line => "$",
        .start_text => "\\A",
        .end_text => "\\z",
        .word_boundary => "\\b",
        .non_word_boundary => "\\B",
    };
}

/// DRY helper: Convert quantifier mode to its suffix character(s)
fn quantifierModeSuffix(mode: ast.Node.QuantifierMode) []const u8 {
    return switch (mode) {
        .greedy => "",
        .lazy => "?",
        .possessive => "+",
    };
}

/// DRY helper: Print character class ranges to a writer
fn printCharRanges(ranges: []const common.CharRange, writer: anytype) !void {
    for (ranges) |range| {
        if (range.start == range.end) {
            try writer.print("{u}", .{range.start});
        } else {
            try writer.print("{u}-{u}", .{ range.start, range.end });
        }
    }
}

/// AST pretty-printer for debugging and visualization
/// Provides multiple output formats: tree view, S-expression, and DOT graph
pub const PrettyPrinter = struct {
    allocator: std.mem.Allocator,
    indent_size: usize,

    pub const Format = enum {
        tree, // Human-readable tree view
        sexpr, // S-expression format
        dot, // Graphviz DOT format
        compact, // Compact single-line format
    };

    pub fn init(allocator: std.mem.Allocator) PrettyPrinter {
        return .{
            .allocator = allocator,
            .indent_size = 2,
        };
    }

    /// Print AST to writer in specified format
    pub fn print(self: *PrettyPrinter, node: *ast.Node, writer: anytype, format: Format) !void {
        switch (format) {
            .tree => try self.printTree(node, writer, 0),
            .sexpr => try self.printSExpr(node, writer),
            .dot => try self.printDot(node, writer),
            .compact => try self.printCompact(node, writer),
        }
    }

    /// Print as a tree structure
    fn printTree(self: *PrettyPrinter, node: *ast.Node, writer: anytype, depth: usize) !void {
        const indent = self.indent_size * depth;
        try writer.splatByteAll(' ', indent);

        switch (node.node_type) {
            .literal => {
                try writer.print("Literal: '{u}' (0x{x})\n", .{ node.data.literal.c, node.data.literal.c });
            },
            .any => {
                try writer.writeAll("Any (.)\n");
            },
            .empty => {
                try writer.writeAll("Empty (ε)\n");
            },
            .atomic_group => {
                try writer.writeAll("AtomicGroup (?>...)\n");
                try self.printTree(node.data.atomic_group.child, writer, depth + 1);
            },
            .conditional => {
                const cond = node.data.conditional;
                try writer.writeAll("Conditional (?(...)\n");
                try self.printTree(cond.yes_branch, writer, depth + 1);
                if (cond.no_branch) |no| {
                    try self.printTree(no, writer, depth + 1);
                }
            },
            .anchor => {
                const anchor_str = switch (node.data.anchor.type) {
                    .start_line => "^ (start of line)",
                    .end_line => "$ (end of line)",
                    .start_text => "\\A (start of text)",
                    .end_text => "\\z (end of text)",
                    .word_boundary => "\\b (word boundary)",
                    .non_word_boundary => "\\B (non-word boundary)",
                };
                try writer.print("Anchor: {s}\n", .{anchor_str});
            },
            .char_class => {
                const class_data = node.data.char_class;
                const negated = if (class_data.class.negated) "^" else "";
                try writer.print("CharClass: [{s}", .{negated});
                try printCharRanges(class_data.class.ranges, writer);
                try writer.writeAll("]\n");
            },
            .concat => {
                try writer.writeAll("Concat\n");
                try self.printTree(node.data.concat.left, writer, depth + 1);
                try self.printTree(node.data.concat.right, writer, depth + 1);
            },
            .alternation => {
                try writer.writeAll("Alternation (|)\n");
                try self.printTree(node.data.alternation.left, writer, depth + 1);
                try self.printTree(node.data.alternation.right, writer, depth + 1);
            },
            .star => {
                const suffix = quantifierModeSuffix(node.data.star.mode);
                try writer.print("Star (*{s})\n", .{suffix});
                try self.printTree(node.data.star.child, writer, depth + 1);
            },
            .plus => {
                const suffix = quantifierModeSuffix(node.data.plus.mode);
                try writer.print("Plus (+{s})\n", .{suffix});
                try self.printTree(node.data.plus.child, writer, depth + 1);
            },
            .optional => {
                const suffix = quantifierModeSuffix(node.data.optional.mode);
                try writer.print("Optional (?{s})\n", .{suffix});
                try self.printTree(node.data.optional.child, writer, depth + 1);
            },
            .repeat => {
                const repeat = node.data.repeat;
                const suffix = quantifierModeSuffix(repeat.mode);
                if (repeat.bounds.max) |max| {
                    try writer.print("Repeat {{{d},{d}}}{s}\n", .{ repeat.bounds.min, max, suffix });
                } else {
                    try writer.print("Repeat {{{d},}}{s}\n", .{ repeat.bounds.min, suffix });
                }
                try self.printTree(repeat.child, writer, depth + 1);
            },
            .group => {
                const group = node.data.group;
                if (group.capture_index) |index| {
                    if (group.name) |name| {
                        try writer.print("Group (#{d} \"{s}\")\n", .{ index, name });
                    } else {
                        try writer.print("Group (#{d})\n", .{index});
                    }
                } else {
                    try writer.writeAll("Group (non-capturing)\n");
                }
                try self.printTree(group.child, writer, depth + 1);
            },
            .lookahead => {
                const positive = if (node.data.lookahead.positive) "positive" else "negative";
                try writer.print("Lookahead ({s})\n", .{positive});
                try self.printTree(node.data.lookahead.child, writer, depth + 1);
            },
            .lookbehind => {
                const positive = if (node.data.lookbehind.positive) "positive" else "negative";
                try writer.print("Lookbehind ({s})\n", .{positive});
                try self.printTree(node.data.lookbehind.child, writer, depth + 1);
            },
            .backref => {
                const backref = node.data.backref;
                if (backref.name) |name| {
                    try writer.print("Backref: \\k<{s}>\n", .{name});
                } else {
                    try writer.print("Backref: \\{d}\n", .{backref.index});
                }
            },
            .extended_grapheme => {
                try writer.writeAll("ExtendedGrapheme (\\X)\n");
            },
            .recursion => {
                const target = node.data.recursion;
                switch (target) {
                    .whole_pattern => try writer.writeAll("Recursion (whole pattern) (?R)\n"),
                    .group_number => |n| try writer.print("Recursion (group {d}) (?{d})\n", .{ n, n }),
                }
            },
        }
    }

    /// Print as S-expression
    fn printSExpr(self: *PrettyPrinter, node: *ast.Node, writer: anytype) !void {
        switch (node.node_type) {
            .literal => {
                try writer.print("(lit '{u}')", .{node.data.literal.c});
            },
            .any => {
                try writer.writeAll("(any)");
            },
            .empty => {
                try writer.writeAll("(empty)");
            },
            .extended_grapheme => {
                try writer.writeAll("(ext-grapheme)");
            },
            .recursion => {
                const target = node.data.recursion;
                switch (target) {
                    .whole_pattern => try writer.writeAll("(recursion whole-pattern)"),
                    .group_number => |n| try writer.print("(recursion group-{d})", .{n}),
                }
            },
            .anchor => {
                const anchor_str = anchorToString(node.data.anchor.type);
                try writer.print("Anchor\\n{s}", .{anchor_str});
            },
            .char_class => {
                try writer.writeAll("(class ");
                const class = node.data.char_class;
                if (class.class.negated) try writer.writeAll("^ ");
                try printCharRanges(class.class.ranges, writer);
                try writer.writeAll(")");
            },
            .concat => {
                try writer.writeAll("(concat ");
                try self.printSExpr(node.data.concat.left, writer);
                try writer.writeAll(" ");
                try self.printSExpr(node.data.concat.right, writer);
                try writer.writeAll(")");
            },
            .alternation => {
                try writer.writeAll("(or ");
                try self.printSExpr(node.data.alternation.left, writer);
                try writer.writeAll(" ");
                try self.printSExpr(node.data.alternation.right, writer);
                try writer.writeAll(")");
            },
            .star => {
                const op = switch (node.data.star.mode) {
                    .greedy => "star",
                    .lazy => "star-lazy",
                    .possessive => "star-possessive",
                };
                try writer.print("({s} ", .{op});
                try self.printSExpr(node.data.star.child, writer);
                try writer.writeAll(")");
            },
            .plus => {
                const op = switch (node.data.plus.mode) {
                    .greedy => "plus",
                    .lazy => "plus-lazy",
                    .possessive => "plus-possessive",
                };
                try writer.print("({s} ", .{op});
                try self.printSExpr(node.data.plus.child, writer);
                try writer.writeAll(")");
            },
            .optional => {
                const op = switch (node.data.optional.mode) {
                    .greedy => "opt",
                    .lazy => "opt-lazy",
                    .possessive => "opt-possessive",
                };
                try writer.print("({s} ", .{op});
                try self.printSExpr(node.data.optional.child, writer);
                try writer.writeAll(")");
            },
            .repeat => {
                const repeat = node.data.repeat;
                const op = switch (repeat.mode) {
                    .greedy => "repeat",
                    .lazy => "repeat-lazy",
                    .possessive => "repeat-possessive",
                };
                if (repeat.bounds.max) |max| {
                    try writer.print("({s} {d} {d} ", .{ op, repeat.bounds.min, max });
                } else {
                    try writer.print("({s} {d} inf ", .{ op, repeat.bounds.min });
                }
                try self.printSExpr(repeat.child, writer);
                try writer.writeAll(")");
            },
            .group => {
                const group = node.data.group;
                if (group.capture_index) |index| {
                    try writer.print("(group {d} ", .{index});
                } else {
                    try writer.writeAll("(group non-cap ");
                }
                try self.printSExpr(group.child, writer);
                try writer.writeAll(")");
            },
            .lookahead => {
                const positive = node.data.lookahead.positive;
                try writer.writeAll(if (positive) "(lookahead " else "(neg-lookahead ");
                try self.printSExpr(node.data.lookahead.child, writer);
                try writer.writeAll(")");
            },
            .lookbehind => {
                const positive = node.data.lookbehind.positive;
                try writer.writeAll(if (positive) "(lookbehind " else "(neg-lookbehind ");
                try self.printSExpr(node.data.lookbehind.child, writer);
                try writer.writeAll(")");
            },
            .atomic_group => {
                try writer.writeAll("(atomic ");
                try self.printSExpr(node.data.atomic_group.child, writer);
                try writer.writeAll(")");
            },
            .backref => {
                try writer.print("(backref {d})", .{node.data.backref.index});
            },
            .conditional => {
                const cond = node.data.conditional;
                switch (cond.condition) {
                    .group_number => |n| try writer.print("(cond group-{d} ", .{n}),
                    .group_name => |name| try writer.print("(cond '{s}' ", .{name}),
                    .assertion => try writer.writeAll("(cond assert "),
                }
                try self.printSExpr(cond.yes_branch, writer);
                if (cond.no_branch) |no| {
                    try writer.writeAll(" ");
                    try self.printSExpr(no, writer);
                }
                try writer.writeAll(")");
            },
        }
    }

    /// Print as Graphviz DOT format for visualization
    fn printDot(self: *PrettyPrinter, node: *ast.Node, writer: anytype) !void {
        try writer.writeAll("digraph AST {\n");
        try writer.writeAll("  node [shape=box, style=rounded];\n");
        try writer.writeAll("  edge [arrowhead=vee];\n\n");

        var node_id: usize = 0;
        try self.printDotNodeRecursive(node, writer, &node_id, null);

        try writer.writeAll("}\n");
    }

    fn printDotNodeRecursive(_: *PrettyPrinter, node: *ast.Node, writer: anytype, node_id: *usize, _: ?usize) !void {
        const current_id = node_id.*;
        node_id.* += 1;

        // Node label
        try writer.print("  n{d} [label=\"", .{current_id});

        switch (node.node_type) {
            .literal => try writer.print("Lit: '{u}'", .{node.data.literal.c}),
            .any => try writer.writeAll("Any"),
            .empty => try writer.writeAll("ε"),
            .extended_grapheme => try writer.writeAll("ExtGrapheme (\\X)"),
            .recursion => try writer.writeAll("Recursion"),
            .anchor => try writer.writeAll("Anchor"),
            .char_class => try writer.writeAll("CharClass"),
            .concat => try writer.writeAll("Concat"),
            .alternation => try writer.writeAll("Alt"),
            .star, .plus, .optional, .repeat => try writer.writeAll("Quantifier"),
            .group => try writer.writeAll("Group"),
            .lookahead, .lookbehind => try writer.writeAll("Look"),
            .atomic_group => try writer.writeAll("Atomic"),
            .backref => try writer.writeAll("Backref"),
            .conditional => try writer.writeAll("Cond"),
        }
    }

    /// Print as DOT graph node (entry point)
    fn printDotNode(self: *PrettyPrinter, node: *ast.Node, writer: anytype) !void {
        var node_id: usize = 0;
        try self.printDotNodeRecursive(node, writer, &node_id, null);
    }

    /// Print in compact single-line format (reconstructs regex)
    fn printCompact(self: *PrettyPrinter, node: *ast.Node, writer: anytype) !void {
        switch (node.node_type) {
            .literal => {
                const c = node.data.literal.c;
                // Escape special chars
                if (isSpecialChar(c)) {
                    try writer.print("\\{u}", .{c});
                } else {
                    try writer.print("{u}", .{c});
                }
            },
            .any => try writer.writeAll("."),
            .empty => {},
            .extended_grapheme => try writer.writeAll("\\X"),
            .recursion => {
                const target = node.data.recursion;
                switch (target) {
                    .whole_pattern => try writer.writeAll("(?R)"),
                    .group_number => |n| try writer.print("(?{d})", .{n}),
                }
            },
            .anchor => {
                const anchor_str = anchorToString(node.data.anchor.type);
                try writer.writeAll(anchor_str);
            },
            .char_class => {
                const class = node.data.char_class;
                try writer.writeAll("[");
                if (class.class.negated) try writer.writeAll("^");
                try printCharRanges(class.class.ranges, writer);
                try writer.writeAll("]");
            },
            .concat => {
                try self.printCompact(node.data.concat.left, writer);
                try self.printCompact(node.data.concat.right, writer);
            },
            .alternation => {
                try self.printCompact(node.data.alternation.left, writer);
                try writer.writeAll("|");
                try self.printCompact(node.data.alternation.right, writer);
            },
            .star => {
                try self.printCompact(node.data.star.child, writer);
                try writer.writeAll("*");
                try writer.writeAll(quantifierModeSuffix(node.data.star.mode));
            },
            .plus => {
                try self.printCompact(node.data.plus.child, writer);
                try writer.writeAll("+");
                try writer.writeAll(quantifierModeSuffix(node.data.plus.mode));
            },
            .optional => {
                try self.printCompact(node.data.optional.child, writer);
                try writer.writeAll("?");
                try writer.writeAll(quantifierModeSuffix(node.data.optional.mode));
            },
            .repeat => {
                const repeat = node.data.repeat;
                try self.printCompact(repeat.child, writer);
                if (repeat.bounds.max) |max| {
                    try writer.print("{{{d},{d}}}", .{ repeat.bounds.min, max });
                } else {
                    try writer.print("{{{d},}}", .{repeat.bounds.min});
                }
                try writer.writeAll(quantifierModeSuffix(repeat.mode));
            },
            .group => {
                const group = node.data.group;
                if (group.capture_index) |_| {
                    try writer.writeAll("(");
                } else {
                    try writer.writeAll("(?:");
                }
                try self.printCompact(group.child, writer);
                try writer.writeAll(")");
            },
            .lookahead => {
                if (node.data.lookahead.positive) {
                    try writer.writeAll("(?=");
                } else {
                    try writer.writeAll("(?!");
                }
                try self.printCompact(node.data.lookahead.child, writer);
                try writer.writeAll(")");
            },
            .lookbehind => {
                if (node.data.lookbehind.positive) {
                    try writer.writeAll("(?<=");
                } else {
                    try writer.writeAll("(?<!");
                }
                try self.printCompact(node.data.lookbehind.child, writer);
                try writer.writeAll(")");
            },
            .atomic_group => {
                try writer.writeAll("(?>");
                try self.printCompact(node.data.atomic_group.child, writer);
                try writer.writeAll(")");
            },
            .backref => {
                try writer.print("\\{d}", .{node.data.backref.index});
            },
            .conditional => {
                try writer.writeAll("(?(...))");
            },
        }
    }

    fn isSpecialChar(c: u21) bool {
        return switch (c) {
            '.', '*', '+', '?', '|', '(', ')', '[', ']', '{', '}', '^', '$', '\\' => true,
            else => false,
        };
    }
};

/// AST statistics for analysis
pub const ASTStats = struct {
    node_count: usize = 0,
    max_depth: usize = 0,
    literal_count: usize = 0,
    quantifier_count: usize = 0,
    group_count: usize = 0,
    alternation_count: usize = 0,
    backref_count: usize = 0,
    assertion_count: usize = 0,

    pub fn compute(node: *ast.Node) ASTStats {
        var stats = ASTStats{};
        computeRecursive(node, &stats, 0);
        return stats;
    }

    fn computeRecursive(node: *ast.Node, stats: *ASTStats, depth: usize) void {
        stats.node_count += 1;
        stats.max_depth = @max(stats.max_depth, depth);

        switch (node.node_type) {
            .literal => stats.literal_count += 1,
            .star, .plus, .optional, .repeat => stats.quantifier_count += 1,
            .group => stats.group_count += 1,
            .alternation => stats.alternation_count += 1,
            .backref => stats.backref_count += 1,
            .lookahead, .lookbehind => stats.assertion_count += 1,
            else => {},
        }

        // Recurse
        switch (node.node_type) {
            .concat => {
                computeRecursive(node.data.concat.left, stats, depth + 1);
                computeRecursive(node.data.concat.right, stats, depth + 1);
            },
            .alternation => {
                computeRecursive(node.data.alternation.left, stats, depth + 1);
                computeRecursive(node.data.alternation.right, stats, depth + 1);
            },
            .star => computeRecursive(node.data.star.child, stats, depth + 1),
            .plus => computeRecursive(node.data.plus.child, stats, depth + 1),
            .optional => computeRecursive(node.data.optional.child, stats, depth + 1),
            .repeat => computeRecursive(node.data.repeat.child, stats, depth + 1),
            .group => computeRecursive(node.data.group.child, stats, depth + 1),
            .lookahead => computeRecursive(node.data.lookahead.child, stats, depth + 1),
            .lookbehind => computeRecursive(node.data.lookbehind.child, stats, depth + 1),
            .atomic_group => computeRecursive(node.data.atomic_group.child, stats, depth + 1),
            .conditional => {
                const cond = node.data.conditional;
                computeRecursive(cond.yes_branch, stats, depth + 1);
                if (cond.no_branch) |no| computeRecursive(no, stats, depth + 1);
            },
            else => {},
        }
    }

    pub fn print(self: ASTStats, writer: anytype) !void {
        try writer.writeAll("AST Statistics:\n");
        try writer.print("  Total nodes: {d}\n", .{self.node_count});
        try writer.print("  Max depth: {d}\n", .{self.max_depth});
        try writer.print("  Literals: {d}\n", .{self.literal_count});
        try writer.print("  Quantifiers: {d}\n", .{self.quantifier_count});
        try writer.print("  Groups: {d}\n", .{self.group_count});
        try writer.print("  Alternations: {d}\n", .{self.alternation_count});
        try writer.print("  Backreferences: {d}\n", .{self.backref_count});
        try writer.print("  Assertions: {d}\n", .{self.assertion_count});
    }
};

test "pretty print: tree format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "a+b", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var printer = PrettyPrinter.init(allocator);
    try printer.print(tree.root, &aw.writer, .tree);

    try std.testing.expect(aw.writer.end > 0);
}

test "pretty print: sexpr format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "a|b", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var printer = PrettyPrinter.init(allocator);
    try printer.print(tree.root, &aw.writer, .sexpr);

    try std.testing.expect(aw.writer.end > 0);
}

test "pretty print: compact format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "a+b*", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var printer = PrettyPrinter.init(allocator);
    try printer.print(tree.root, &aw.writer, .compact);

    try std.testing.expect(aw.writer.end > 0);
}

test "AST stats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "(a+|b)*c", .{});
    var tree = try p.parse();
    defer tree.deinit();

    const stats = ASTStats.compute(tree.root);

    try std.testing.expect(stats.node_count > 0);
    try std.testing.expect(stats.quantifier_count >= 2); // + and *
    try std.testing.expect(stats.alternation_count >= 1); // |
}

test "printCompact: positive lookahead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "foo(?=bar)", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buf.deinit(allocator);

    var printer = PrettyPrinter.init(allocator);
    try printer.printCompact(tree.root, buf.writer(allocator));

    try std.testing.expectEqualStrings("foo(?=bar)", buf.items);
}

test "printCompact: negative lookahead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "foo(?!bar)", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buf.deinit(allocator);

    var printer = PrettyPrinter.init(allocator);
    try printer.printCompact(tree.root, buf.writer(allocator));

    try std.testing.expectEqualStrings("foo(?!bar)", buf.items);
}

test "printCompact: positive lookbehind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "(?<=foo)bar", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buf.deinit(allocator);

    var printer = PrettyPrinter.init(allocator);
    try printer.printCompact(tree.root, buf.writer(allocator));

    try std.testing.expectEqualStrings("(?<=foo)bar", buf.items);
}

test "printCompact: negative lookbehind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "(?<!foo)bar", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buf.deinit(allocator);

    var printer = PrettyPrinter.init(allocator);
    try printer.printCompact(tree.root, buf.writer(allocator));

    try std.testing.expectEqualStrings("(?<!foo)bar", buf.items);
}

test "printCompact: atomic group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "(?>a+)b", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buf.deinit(allocator);

    var printer = PrettyPrinter.init(allocator);
    try printer.printCompact(tree.root, buf.writer(allocator));

    try std.testing.expectEqualStrings("(?>a+)b", buf.items);
}

test "printCompact: nested lookaround" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "(?=a(?!b))", .{});
    var tree = try p.parse();
    defer tree.deinit();

    var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buf.deinit(allocator);

    var printer = PrettyPrinter.init(allocator);
    try printer.printCompact(tree.root, buf.writer(allocator));

    try std.testing.expectEqualStrings("(?=a(?!b))", buf.items);
}
