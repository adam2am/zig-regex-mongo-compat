const std = @import("std");
const regex = @import("regex");
const testing = std.testing;

test "Unicode digit property - Tibetan digits" {
    const allocator = testing.allocator;

    // Test 96: (*UCP)\d+ should match Tibetan digits ༢༣༤༥.
    const pattern = "(*UCP)\\d+";
    const input = "\u{0F22}\u{0F23}\u{0F24}\u{0F25}";

    var re = try regex.Regex.compile(allocator, pattern);
    defer re.deinit();

    const result = try re.isMatch(input);
    try testing.expect(result);
}

test "Unicode letter property - café" {
    const allocator = testing.allocator;

    // Test 98: (*UCP)[[:alpha:]]+ should match café.
    const pattern = "(*UCP)[[:alpha:]]+";
    const input = "caf\u{00E9}";

    var re = try regex.Regex.compile(allocator, pattern);
    defer re.deinit();

    const result = try re.isMatch(input);
    try testing.expect(result);
}

test "Unicode digit - ASCII digits still work" {
    const allocator = testing.allocator;

    const pattern = "(*UCP)\\d+";
    const input = "123";

    var re = try regex.Regex.compile(allocator, pattern);
    defer re.deinit();

    const result = try re.isMatch(input);
    try testing.expect(result);
}

test "Unicode letter - ASCII letters still work" {
    const allocator = testing.allocator;

    const pattern = "(*UCP)[[:alpha:]]+";
    const input = "hello";

    var re = try regex.Regex.compile(allocator, pattern);
    defer re.deinit();

    const result = try re.isMatch(input);
    try testing.expect(result);
}

test "word boundary without UCP treats non-ASCII letters as non-word" {
    const allocator = testing.allocator;
    var re = try regex.Regex.compile(allocator, "\\b\u{00D6}yster");
    defer re.deinit();

    try testing.expect(!try re.isMatch("\u{00D6}yster"));
}

test "word boundary with UCP treats non-ASCII letters as word chars" {
    const allocator = testing.allocator;
    var re = try regex.Regex.compile(allocator, "(*UCP)\\b\u{00D6}yster");
    defer re.deinit();

    try testing.expect(try re.isMatch("\u{00D6}yster"));
}

test "Unicode property: empty braces are rejected" {
    const allocator = testing.allocator;
    try testing.expectError(regex.RegexError.InvalidUnicodeProperty, regex.Regex.compile(allocator, "\\p{}"));
}
