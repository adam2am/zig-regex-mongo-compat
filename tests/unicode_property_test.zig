const std = @import("std");
const regex = @import("regex");
const testing = std.testing;

test "Unicode digit property - Tibetan digits" {
    const allocator = testing.allocator;

    // Test 96: (*UCP)\d+ should match Tibetan digits ༢༣༤༥
    const pattern = "(*UCP)\\d+";
    const input = "༢༣༤༥"; // Tibetan digits 2, 3, 4, 5

    var re = try regex.Regex.compile(allocator, pattern);
    defer re.deinit();

    const result = try re.isMatch(input);
    try testing.expect(result);
}

test "Unicode letter property - café" {
    const allocator = testing.allocator;

    // Test 98: (*UCP)[[:alpha:]]+ should match café
    const pattern = "(*UCP)[[:alpha:]]+";
    const input = "café";

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
