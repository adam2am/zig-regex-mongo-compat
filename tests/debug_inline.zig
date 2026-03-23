const std = @import("std");
const Regex = @import("regex").Regex;

test "inline modifier (?i) - simple case" {
    const allocator = std.heap.page_allocator;
    var regex1 = try Regex.compile(allocator, "a(?i)bc");
    defer regex1.deinit();
    try std.testing.expect(try regex1.isMatch("aBC"));
}

test "inline modifier (?i:...) - scoped" {
    const allocator = std.heap.page_allocator;
    var regex2 = try Regex.compile(allocator, "a(?i:bc)d");
    defer regex2.deinit();
    try std.testing.expect(try regex2.isMatch("aBCd"));
}

test "inline modifier (?i) - case-sensitive prefix" {
    const allocator = std.heap.page_allocator;
    var regex3 = try Regex.compile(allocator, "a(?i)bc");
    defer regex3.deinit();
    try std.testing.expect(!try regex3.isMatch("ABC"));
}

test "inline modifier (?i:...) - case-sensitive suffix" {
    const allocator = std.heap.page_allocator;
    var regex4 = try Regex.compile(allocator, "a(?i:bc)d");
    defer regex4.deinit();
    try std.testing.expect(!try regex4.isMatch("aBCD"));
}

test "inline modifier (?im) - multiple modifiers" {
    const allocator = std.heap.page_allocator;
    var regex5 = try Regex.compile(allocator, "(?im)^test$");
    defer regex5.deinit();
    try std.testing.expect(try regex5.isMatch("TEST"));
}
