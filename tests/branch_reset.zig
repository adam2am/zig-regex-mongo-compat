const std = @import("std");
const Regex = @import("regex").Regex;

test "branch reset: basic (?|a(b)|c(d))" {
    const allocator = std.testing.allocator;

    // Both branches have group 1, not group 1 and 2
    var regex = try Regex.compile(allocator, "(?|a(b)|c(d))");
    defer regex.deinit();

    // Match first branch "ab" - group 1 should be "b"
    try std.testing.expect(try regex.isMatch("ab"));

    // Match second branch "cd" - group 1 should be "d"
    try std.testing.expect(try regex.isMatch("cd"));

    // Should not match other strings
    try std.testing.expect(!try regex.isMatch("ac"));
    try std.testing.expect(!try regex.isMatch("bd"));
}

test "branch reset: with outer group (x)(?|(a)(b)|(c)(d))(y)" {
    const allocator = std.testing.allocator;

    // Group 1: x, Group 2: a or c, Group 3: b or d, Group 4: y
    var regex = try Regex.compile(allocator, "(x)(?|(a)(b)|(c)(d))(y)");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("xaby"));
    try std.testing.expect(try regex.isMatch("xcdy"));
    try std.testing.expect(!try regex.isMatch("xacy"));
}

test "branch reset: nested (?|(?|a(b)|c(d))|e(f))" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "(?|(?|a(b)|c(d))|e(f))");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("ab"));
    try std.testing.expect(try regex.isMatch("cd"));
    try std.testing.expect(try regex.isMatch("ef"));
}

test "branch reset: with backreference (?|(a)\\1|(b)\\1)" {
    const allocator = std.testing.allocator;

    // Both branches use group 1, backreference should work
    var regex = try Regex.compile(allocator, "(?|(a)\\1|(b)\\1)");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("aa"));
    try std.testing.expect(try regex.isMatch("bb"));
    try std.testing.expect(!try regex.isMatch("ab"));
    try std.testing.expect(!try regex.isMatch("ba"));
}

test "branch reset: empty alternatives (?||)" {
    const allocator = std.testing.allocator;

    // Empty alternatives should match empty string
    var regex = try Regex.compile(allocator, "(?||)");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
}

test "branch reset: at pattern start (?|a|b)" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "(?|a|b)");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("b"));
}

test "branch reset: at pattern end x(?|a|b)" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "x(?|a|b)");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("xa"));
    try std.testing.expect(try regex.isMatch("xb"));
}

test "branch reset: multiple in sequence (?|a|b)(?|c|d)" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "(?|a|b)(?|c|d)");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("ac"));
    try std.testing.expect(try regex.isMatch("ad"));
    try std.testing.expect(try regex.isMatch("bc"));
    try std.testing.expect(try regex.isMatch("bd"));
}

test "branch reset: with quantifier (?|a|b)+" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "(?|a|b)+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("b"));
    try std.testing.expect(try regex.isMatch("aa"));
    try std.testing.expect(try regex.isMatch("ab"));
    try std.testing.expect(try regex.isMatch("ba"));
    try std.testing.expect(try regex.isMatch("aaabbb"));
}
