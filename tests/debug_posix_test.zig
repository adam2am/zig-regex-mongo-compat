const std = @import("std");
const regex = @import("regex");
const testing = std.testing;

test "POSIX alpha class compiles" {
    const allocator = testing.allocator;
    var re = try regex.Regex.compile(allocator, "[[:alpha:]]");
    defer re.deinit();
}

test "POSIX alpha class with UCP matches café" {
    const allocator = testing.allocator;
    var re = try regex.Regex.compile(allocator, "(*UCP)[[:alpha:]]+");
    defer re.deinit();

    try testing.expect(try re.isMatch("café"));
}
