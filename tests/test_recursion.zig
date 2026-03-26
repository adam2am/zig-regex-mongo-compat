const std = @import("std");
const regex = @import("regex");

test "simple pattern compiles and matches" {
    const allocator = std.heap.page_allocator;
    var r = try regex.Regex.compile(allocator, "abc");
    defer r.deinit();
    const match = try r.isMatch("abc");
    try std.testing.expect(match);
}

test "(*UTF) prefix is parsed correctly" {
    const allocator = std.heap.page_allocator;
    var r = try regex.Regex.compile(allocator, "(*UTF)café");
    defer r.deinit();
    try std.testing.expect(r.flags.unicode);
}

test "\\p{Latin} unicode property is parsed correctly" {
    const allocator = std.heap.page_allocator;
    var r = try regex.Regex.compile(allocator, "\\p{Latin}");
    defer r.deinit();
}

test "\\p{Any} matches any character" {
    const allocator = std.heap.page_allocator;
    var r = try regex.Regex.compile(allocator, "\\p{Any}+");
    defer r.deinit();

    try std.testing.expect(try r.isMatch("abc"));
    try std.testing.expect(try r.isMatch("123"));
    try std.testing.expect(try r.isMatch("café"));
    try std.testing.expect(try r.isMatch("你好"));
    try std.testing.expect(try r.isMatch("👋🔥"));
}

test "\\p{Any} with negation" {
    const allocator = std.heap.page_allocator;
    var r = try regex.Regex.compile(allocator, "\\P{Any}");
    defer r.deinit();

    // \P{Any} should never match (negation of "any character")
    try std.testing.expect(!try r.isMatch("a"));
    try std.testing.expect(!try r.isMatch("1"));
    try std.testing.expect(!try r.isMatch("\n"));
}
