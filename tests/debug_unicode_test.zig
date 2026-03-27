const std = @import("std");
const regex = @import("regex");
const testing = std.testing;

test "UCP flag enables unicode mode" {
    const allocator = testing.allocator;
    var re = try regex.Regex.compile(allocator, "(*UCP)\\d+");
    defer re.deinit();

    try testing.expect(re.flags.unicode);
}

test "UCP digit class matches Tibetan digit" {
    const allocator = testing.allocator;
    var re = try regex.Regex.compile(allocator, "(*UCP)\\d");
    defer re.deinit();

    try testing.expect(try re.isMatch("༢"));
}
