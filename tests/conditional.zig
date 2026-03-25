const std = @import("std");
const Regex = @import("regex").Regex;

test "conditional: group number - group captured" {
    var re = try Regex.compile(std.testing.allocator, "(a)?(?(1)b|c)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
}

test "conditional: group number - group not captured" {
    var re = try Regex.compile(std.testing.allocator, "(a)?(?(1)b|c)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("c"));
}

test "conditional: no else branch - condition met" {
    var re = try Regex.compile(std.testing.allocator, "(a)?(?(1)b)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
}

test "conditional: no else branch - condition not met" {
    var re = try Regex.compile(std.testing.allocator, "(a)?(?(1)b)");
    defer re.deinit();

    // When group 1 is not captured and there's no else branch, match succeeds
    try std.testing.expect(try re.isMatch(""));
}

test "conditional: assertion condition - positive lookahead true" {
    var re = try Regex.compile(std.testing.allocator, "(?(?=a)ab|cd)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
}

test "conditional: assertion condition - positive lookahead false" {
    var re = try Regex.compile(std.testing.allocator, "(?(?=a)ab|cd)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("cd"));
}

test "conditional: assertion condition - negative lookahead" {
    var re = try Regex.compile(std.testing.allocator, "(?(?!a)cd|ab)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("cd"));
}

test "conditional: nested in group" {
    var re = try Regex.compile(std.testing.allocator, "((a)?(?(2)b|c))");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
}

test "conditional: multiple conditionals" {
    var re = try Regex.compile(std.testing.allocator, "(a)?(b)?(?(1)x)(?(2)y)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("abxy"));
}

test "conditional: with quantifiers" {
    var re = try Regex.compile(std.testing.allocator, "(a)?(?(1)b+|c+)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("abbb"));
}
