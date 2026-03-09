const std = @import("std");
const Regex = @import("regex").Regex;

// ============================================================================
// BASELINE TESTS: Current functionality (should PASS)
// ============================================================================

test "baseline: global case_insensitive flag works" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "abc", .{ .case_insensitive = true });
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("ABC"));
    try std.testing.expect(try regex.isMatch("AbC"));
}

test "baseline: global multiline flag works" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "^test$", .{ .multiline = true });
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("test"));
    try std.testing.expect(try regex.isMatch("line1\ntest\nline3"));
}

test "baseline: global dot_all flag works" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "a.b", .{ .dot_all = true });
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a\nb"));
    try std.testing.expect(try regex.isMatch("axb"));
}

test "baseline: null byte in pattern should error" {
    const allocator = std.testing.allocator;

    // This tests the actual null byte validation in the parser
    const pattern_with_null = "te\x00st";
    const result = Regex.compile(allocator, pattern_with_null);

    // Should return an error (null bytes not allowed in patterns)
    try std.testing.expectError(error.InvalidPattern, result);
}

// ============================================================================
// TDD TESTS: Inline modifiers (should FAIL until implemented)
// ============================================================================

test "inline modifier: (?i) makes rest case-insensitive" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a(?i)bc");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("aBC")); // Only bc is case-insensitive
    try std.testing.expect(!try regex.isMatch("Abc")); // 'a' is still case-sensitive
}

test "inline modifier: (?i:...) scoped case-insensitive" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a(?i:bc)d");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abcd"));
    try std.testing.expect(try regex.isMatch("aBCd")); // Only bc is case-insensitive
    try std.testing.expect(!try regex.isMatch("Abcd")); // 'a' is case-sensitive
    try std.testing.expect(!try regex.isMatch("abcD")); // 'd' is case-sensitive
}

test "inline modifier: (?-i) disables case-insensitive" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compileWithFlags(allocator, "a(?-i)bc", .{ .case_insensitive = true });
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("Abc")); // 'a' is case-insensitive
    try std.testing.expect(!try regex.isMatch("ABC")); // bc is case-sensitive after (?-i)
}

test "inline modifier: (?m) multiline mode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?m)^test$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("test"));
    try std.testing.expect(try regex.isMatch("line1\ntest\nline3"));
}

test "inline modifier: (?s) dot-all mode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?s)a.b");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a\nb"));
    try std.testing.expect(try regex.isMatch("axb"));
}

test "inline modifier: (?im) multiple flags" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?im)^test$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("TEST"));
    try std.testing.expect(try regex.isMatch("line1\nTEST\nline3"));
}

test "inline modifier: nested scopes" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?i:a(?-i:b)c)");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("Abc")); // 'a' is case-insensitive
    try std.testing.expect(try regex.isMatch("abC")); // 'c' is case-insensitive
    try std.testing.expect(!try regex.isMatch("aBc")); // 'b' is case-sensitive (nested (?-i:))
}

test "inline modifier: scope inheritance" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?:(?i)abc)def");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("ABCdef")); // abc inherits (?i)
    try std.testing.expect(!try regex.isMatch("ABCDef")); // def is outside scope
}

test "inline modifier: mixed enable/disable" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?i-m)test");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("TEST")); // case-insensitive enabled
    // multiline disabled (but hard to test without context)
}
