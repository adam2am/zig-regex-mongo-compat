const std = @import("std");
const regex = @import("regex");

const Regex = regex.Regex;

test "extended mode ignores # line comments" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "a # comment\n b", .{ .extended = true });
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
}

test "extended mode ignores # comment without preceding whitespace" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "a#comment\nb", .{ .extended = true });
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
}

test "extended mode does not treat # as comment inside char class" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "[#ab]+", .{ .extended = true });
    defer re.deinit();

    try std.testing.expect(try re.isMatch("#ab"));
}

test "extended mode does not treat escaped # as comment" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "a\\#b", .{ .extended = true });
    defer re.deinit();

    try std.testing.expect(try re.isMatch("a#b"));
}

test "inline extended mode ignores # line comments" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(?x)a # comment\n b");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
}

test "disabling extended mode stops # from acting as comment" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(?-x)a#b");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("a#b"));
    try std.testing.expect(!try re.isMatch("ab"));
}

test "extended mode does not strip literal text inside \\Q...\\E" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "\\Qa # not a comment\\E", .{ .extended = true });
    defer re.deinit();

    try std.testing.expect(try re.isMatch("a # not a comment"));
}

test "extended mode comment skips through CRLF" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "a# comment\r\nb", .{ .extended = true });
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
}
