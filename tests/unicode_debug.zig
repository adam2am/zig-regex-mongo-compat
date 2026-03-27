const std = @import("std");
const regex = @import("regex");

test "UCP word boundary matches Öyster at start" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(*UCP)\\bÖyster");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("Öyster"));
}

test "UCP bare word boundary matches at start of Öyster" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(*UCP)\\b");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("Öyster"));
}

test "UCP word boundary char-class pattern matches Öyster" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(*UCP)\\b[Öo]");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("Öyster"));
}
