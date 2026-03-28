const std = @import("std");
const Regex = @import("regex").Regex;

fn buildNestedCapturePattern(allocator: std.mem.Allocator, depth: usize, literal: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (0..depth) |_| {
        try buf.append(allocator, '(');
    }
    try buf.appendSlice(allocator, literal);
    for (0..depth) |_| {
        try buf.append(allocator, ')');
    }

    return buf.toOwnedSlice(allocator);
}

fn expectNestedCaptureMatch(depth: usize) !void {
    const allocator = std.testing.allocator;
    const literal = "abc";

    const pattern = try buildNestedCapturePattern(allocator, depth, literal);
    defer allocator.free(pattern);

    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(literal));
    try std.testing.expect(!try regex.isMatch("abd"));
}

test "deep captures: 128 nested capture groups still match" {
    try expectNestedCaptureMatch(128);
}

test "deep captures: 129 nested capture groups cross historical u8 save boundary" {
    try expectNestedCaptureMatch(129);
}

test "deep captures: 150 nested capture groups from wrapper regression still match" {
    try expectNestedCaptureMatch(150);
}
