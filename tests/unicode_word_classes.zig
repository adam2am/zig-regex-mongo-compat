const std = @import("std");
const regex = @import("regex");

const Regex = regex.Regex;

test "default \\w remains ASCII-only" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "\\w+");
    defer re.deinit();

    if (try re.find("café")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("caf", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "unicode flag makes \\w match non-ASCII letters" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "\\w+", .{ .unicode = true });
    defer re.deinit();

    if (try re.find("café")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("café", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "unicode flag makes \\W invert unicode-aware \\w" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithFlags(allocator, "\\W+", .{ .unicode = true });
    defer re.deinit();

    if (try re.find("Öyster!")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("!", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "(*UCP) makes \\w match Unicode letters" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(*UCP)\\w+");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("Öyster"));
    try std.testing.expect(try re.isMatch("Привет"));
    try std.testing.expect(try re.isMatch("東京"));
}

test "(*UCP) makes \\W treat Unicode letters as word chars" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(*UCP)\\W+");
    defer re.deinit();

    if (try re.find("Öyster!")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("!", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "(*UCP) keeps \\w aligned with Unicode word boundaries" {
    const allocator = std.testing.allocator;
    var word = try Regex.compile(allocator, "(*UCP)\\w+");
    defer word.deinit();
    var boundary = try Regex.compile(allocator, "(*UCP)\\bÖyster");
    defer boundary.deinit();

    try std.testing.expect(try word.isMatch("Öyster"));
    try std.testing.expect(try boundary.isMatch("Öyster soup"));
}
