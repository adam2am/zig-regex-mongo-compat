const std = @import("std");
const regex = @import("regex");

test "UCP word boundary does not split inside Öyster" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(*UCP)\\byster");
    defer re.deinit();

    try std.testing.expect(!try re.isMatch("Öyster"));
}
