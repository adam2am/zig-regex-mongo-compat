const std = @import("std");
const ast = @import("ast.zig");
const RegexError = @import("errors.zig").RegexError;

pub fn validate(root: *ast.Node, capture_count: usize, named_captures: ?*const std.StringArrayHashMap(usize)) RegexError!void {
    try validateNode(root, capture_count, named_captures);
}

fn validateNode(node: *ast.Node, capture_count: usize, named_captures: ?*const std.StringArrayHashMap(usize)) RegexError!void {
    switch (node.node_type) {
        .backref => {
            const backref = node.data.backref;
            if (backref.name) |name| {
                if (name.len == 0) return RegexError.InvalidBackreference;
                const map = named_captures orelse return RegexError.InvalidBackreference;
                if (!map.contains(name)) return RegexError.InvalidBackreference;
            } else {
                if (backref.index == 0 or backref.index > capture_count) return RegexError.InvalidBackreference;
            }
        },
        .concat => {
            try validateNode(node.data.concat.left, capture_count, named_captures);
            try validateNode(node.data.concat.right, capture_count, named_captures);
        },
        .alternation => {
            try validateNode(node.data.alternation.left, capture_count, named_captures);
            try validateNode(node.data.alternation.right, capture_count, named_captures);
        },
        .star => try validateNode(node.data.star.child, capture_count, named_captures),
        .plus => try validateNode(node.data.plus.child, capture_count, named_captures),
        .optional => try validateNode(node.data.optional.child, capture_count, named_captures),
        .repeat => try validateNode(node.data.repeat.child, capture_count, named_captures),
        .group => try validateNode(node.data.group.child, capture_count, named_captures),
        .lookahead => try validateNode(node.data.lookahead.child, capture_count, named_captures),
        .lookbehind => try validateNode(node.data.lookbehind.child, capture_count, named_captures),
        .atomic_group => try validateNode(node.data.atomic_group.child, capture_count, named_captures),
        .conditional => {
            try validateNode(node.data.conditional.yes_branch, capture_count, named_captures);
            if (node.data.conditional.no_branch) |no_branch| {
                try validateNode(no_branch, capture_count, named_captures);
            }
        },
        else => {},
    }
}

test "semantic validator rejects nonexistent numeric backreference" {
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try parser.Parser.init(allocator, "\\9", .{});
    var tree = try p.parse();
    defer tree.deinit();

    try std.testing.expectError(RegexError.InvalidBackreference, validate(tree.root, tree.capture_count, null));
}

test "semantic validator rejects nonexistent named backreference" {
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try parser.Parser.init(allocator, "\\k<missing>", .{});
    var tree = try p.parse();
    defer tree.deinit();

    try std.testing.expectError(RegexError.InvalidBackreference, validate(tree.root, tree.capture_count, null));
}
