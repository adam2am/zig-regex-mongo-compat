const std = @import("std");
const ast = @import("ast.zig");

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

                // Show ranges
                for (class_data.class.ranges) |range| {
                    if (range.start == range.end) {
                        try writer.print("{u}", .{range.start});
                    } else {
                        try writer.print("{u}-{u}", .{ range.start, range.end });
                    }
                }
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
                const mode_str = switch (node.data.star.mode) {
                    .greedy => "",
                    .lazy => "? (lazy)",
                    .possessive => "+ (possessive)",
                };
                try writer.print("Star (*{s})\n", .{mode_str});
                try self.printTree(node.data.star.child, writer, depth + 1);
            },
            .plus => {
                const mode_str = switch (node.data.plus.mode) {
                    .greedy => "",
                    .lazy => "? (lazy)",
                    .possessive => "+ (possessive)",
                };
                try writer.print("Plus (+{s})\n", .{mode_str});
                try self.printTree(node.data.plus.child, writer, depth + 1);
            },
            .optional => {
                const mode_str = switch (node.data.optional.mode) {
                    .greedy => "",
                    .lazy => "? (lazy)",
                    .possessive => "+ (possessive)",
                };
                try writer.print("Optional (?{s})\n", .{mode_str});
                try self.printTree(node.data.optional.child, writer, depth + 1);
            },
            .repeat => {
                const repeat = node.data.repeat;
                const mode_str = switch (repeat.mode) {
                    .greedy => "",
                    .lazy => "? (lazy)",
                    .possessive => "+ (possessive)",
                };
                if (repeat.bounds.max) |max| {
                    try writer.print("Repeat {{{d},{d}}}{s}\n", .{ repeat.bounds.min, max, mode_str });
                } else {
                    try writer.print("Repeat {{{d},}}{s}\n", .{ repeat.bounds.min, mode_str });
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
            .anchor => {
                const anchor_str = anchorToString(node.data.anchor.type);
                try writer.print("Anchor\\n{s}", .{anchor_str});
            },
            .char_class => {
                try writer.writeAll("(class ");
                const class = node.data.char_class;
                if (class.class.negated) try writer.writeAll("^ ");
                for (class.class.ranges) |range| {
                    if (range.start == range.end) {
                        try writer.print("{u} ", .{range.start});
                    } else {
                        try writer.print("{u}-{u} ", .{ range.start, range.end });
                    }
                }
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
                const op = if (node.data.lookahead.positive) "lookahead" else "neg-lookahead";
                try writer.print("({s} ", .{op});
                try self.printSExpr(node.data.lookahead.child, writer);
                try writer.writeAll(")");
            },
            .lookbehind => {
                const op = if (node.data.lookbehind.positive) "lookbehind" else "neg-lookbehind";
                try writer.print("({s} ", .{op});
                try self.printSExpr(node.data.lookbehind.child, writer);
                try writer.writeAll(")");
            },
            .backref => {
                try writer.print("(backref {d})", .{node.data.backref.index});
            },
        }
    }

    /// Print as Graphviz DOT format for visualization
    fn printDot(self: *PrettyPrinter, node: *ast.Node, writer: anytype) !void {
        try writer.writeAll("digraph AST {\n");
        try writer.writeAll("  node [shape=box, style=rounded];\n");
        try writer.writeAll("  edge [arrowhead=vee];\n\n");

        var node_id: usize = 0;
        try self.printDotNode(node, writer, &node_id, null);

        try writer.writeAll("}\n");
    }

    fn printDotNode(self: *PrettyPrinter, node: *ast.Node, writer: anytype, node_id: *usize, parent_id: ?usize) !void {
        const current_id = node_id.*;
        node_id.* += 1;

        // Node label
        try writer.print("  n{d} [label=\"", .{current_id});

        switch (node.node_type) {
            .literal => try writer.print("Lit: '{u}'", .{node.data.literal.c}),
            .any => try writer.writeAll("Any"),
            .empty => try writer.writeAll("ε"),
            .anchor => {
                const anchor_str = anchorToString(node.data.anchor.type);
                try writer.print("Anchor: {s}", .{anchor_str});
            },
            .char_class => try writer.writeAll("CharClass"),
            .concat => try writer.writeAll("Concat"),
            .alternation => try writer.writeAll("Alt (|)"),
            .star => {
                const lazy = if (node.data.star.mode == .greedy) "" else "?";
                try writer.print("Star (*{s})", .{lazy});
            },
            .plus => {
                const lazy = if (node.data.plus.mode == .greedy) "" else "?";
                try writer.print("Plus (+{s})", .{lazy});
            },
            .optional => {
                const lazy = if (node.data.optional.mode == .greedy) "" else "?";
                try writer.print("Opt (?{s})", .{lazy});
            },
            .repeat => {
                const repeat = node.data.repeat;
                const lazy = if (repeat.mode == .greedy) "" else "?";
                if (repeat.bounds.max) |max| {
                    try writer.print("Repeat ({{{d},{d}}}{s})", .{ repeat.bounds.min, max, lazy });
                } else {
                    try writer.print("Repeat ({{{d},}}{s})", .{ repeat.bounds.min, lazy });
                }
            },
            .group => {
                const group = node.data.group;
                if (group.capture_index) |index| {
                    try writer.print("Group\\n#{d}", .{index});
                } else {
                    try writer.writeAll("Group\\n(non-cap)");
                }
            },
            .lookahead => {
                const sign = if (node.data.lookahead.positive) "=" else "!";
                try writer.print("Lookahead\\n(?{s})", .{sign});
            },
            .lookbehind => {
                const sign = if (node.data.lookbehind.positive) "=" else "!";
                try writer.print("Lookbehind\\n(?<{s})", .{sign});
            },
            .backref => try writer.print("Backref\\n\\\\{d}", .{node.data.backref.index}),
        }

        try writer.writeAll("\"];\n");

        // Edge from parent
        if (parent_id) |pid| {
            try writer.print("  n{d} -> n{d};\n", .{ pid, current_id });
        }

        // Recurse to children
        switch (node.node_type) {
            .concat => {
                try self.printDotNode(node.data.concat.left, writer, node_id, current_id);
                try self.printDotNode(node.data.concat.right, writer, node_id, current_id);
            },
            .alternation => {
                try self.printDotNode(node.data.alternation.left, writer, node_id, current_id);
                try self.printDotNode(node.data.alternation.right, writer, node_id, current_id);
            },
            .star => try self.printDotNode(node.data.star.child, writer, node_id, current_id),
            .plus => try self.printDotNode(node.data.plus.child, writer, node_id, current_id),
            .optional => try self.printDotNode(node.data.optional.child, writer, node_id, current_id),
            .repeat => try self.printDotNode(node.data.repeat.child, writer, node_id, current_id),
            .group => try self.printDotNode(node.data.group.child, writer, node_id, current_id),
            .lookahead => try self.printDotNode(node.data.lookahead.child, writer, node_id, current_id),
            .lookbehind => try self.printDotNode(node.data.lookbehind.child, writer, node_id, current_id),
            else => {},
        }
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
            .anchor => {
                const anchor_str = anchorToString(node.data.anchor.type);
                try writer.writeAll(anchor_str);
            },
            .char_class => {
                const class = node.data.char_class;
                try writer.writeAll("[");
                if (class.class.negated) try writer.writeAll("^");
                for (class.class.ranges) |range| {
                    if (range.start == range.end) {
                        try writer.print("{u}", .{range.start});
                    } else {
                        try writer.print("{u}-{u}", .{ range.start, range.end });
                    }
                }
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
                switch (node.data.star.mode) {
                    .greedy => {},
                    .lazy => try writer.writeAll("?"),
                    .possessive => try writer.writeAll("+"),
                }
            },
            .plus => {
                try self.printCompact(node.data.plus.child, writer);
                try writer.writeAll("+");
                switch (node.data.plus.mode) {
                    .greedy => {},
                    .lazy => try writer.writeAll("?"),
                    .possessive => try writer.writeAll("+"),
                }
            },
            .optional => {
                try self.printCompact(node.data.optional.child, writer);
                try writer.writeAll("?");
                switch (node.data.optional.mode) {
                    .greedy => {},
                    .lazy => try writer.writeAll("?"),
                    .possessive => try writer.writeAll("+"),
                }
            },
            .repeat => {
                const repeat = node.data.repeat;
                try self.printCompact(repeat.child, writer);
                if (repeat.bounds.max) |max| {
                    try writer.print("{{{d},{d}}}", .{ repeat.bounds.min, max });
                } else {
                    try writer.print("{{{d},}}", .{repeat.bounds.min});
                }
                switch (repeat.mode) {
                    .greedy => {},
                    .lazy => try writer.writeAll("?"),
                    .possessive => try writer.writeAll("+"),
                }
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
            .backref => {
                try writer.print("\\{d}", .{node.data.backref.index});
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
