const std = @import("std");
const regex = @import("regex");

test "(*UCP)\\bÖyster pattern matching" {
    const allocator = std.testing.allocator;
    const Regex = regex.Regex;

    const pattern = "(*UCP)\\bÖyster";
    const input = "Öyster";

    var re = try Regex.compile(allocator, pattern);
    defer re.deinit();

    const result = try re.isMatch(input);
    std.debug.print("\n=== Test: (*UCP)\\bÖyster ===\n", .{});
    std.debug.print("Pattern: {s}\n", .{pattern});
    std.debug.print("Input: {s}\n", .{input});
    std.debug.print("Match result: {}\n", .{result});
    std.debug.print("Expected: true\n", .{});

    try std.testing.expect(result == true);
}

test "Word boundary at start of Öyster" {
    const allocator = std.testing.allocator;
    const Regex = regex.Regex;

    const pattern = "(*UCP)\\b";
    const input = "Öyster";

    var re = try Regex.compile(allocator, pattern);
    defer re.deinit();

    const result = try re.isMatch(input);
    std.debug.print("\n=== Test: (*UCP)\\b at start ===\n", .{});
    std.debug.print("Pattern: {s}\n", .{pattern});
    std.debug.print("Input: {s}\n", .{input});
    std.debug.print("\\b matches at start: {}\n", .{result});
    std.debug.print("Expected: true\n", .{});

    try std.testing.expect(result == true);
}

test "(*UCP)\\b[Öo] pattern (Test 106 equivalent)" {
    const allocator = std.testing.allocator;
    const Regex = regex.Regex;

    const pattern = "(*UCP)\\b[Öo]";
    const input = "Öyster";

    var re = try Regex.compile(allocator, pattern);
    defer re.deinit();

    const result = try re.isMatch(input);
    std.debug.print("\n=== Test 106 Equivalent ===\n", .{});
    std.debug.print("Pattern: {s}\n", .{pattern});
    std.debug.print("Input: {s}\n", .{input});
    std.debug.print("Match result: {}\n", .{result});
    std.debug.print("Expected: true (Test 106 expects 1)\n", .{});

    try std.testing.expect(result == true);
}
