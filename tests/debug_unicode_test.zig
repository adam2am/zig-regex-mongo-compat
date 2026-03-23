const std = @import("std");
const regex = @import("regex");
const testing = std.testing;

test "Debug: Check if (*UCP) flag is set" {
    const allocator = testing.allocator;

    const pattern = "(*UCP)\\d+";

    var re = try regex.Regex.compile(allocator, pattern);
    defer re.deinit();

    // Just check if it compiles without error
    std.debug.print("\nPattern compiled successfully: {s}\n", .{pattern});
    std.debug.print("Flags: unicode={}\n", .{re.flags.unicode});
}

test "Debug: Match Tibetan digit step by step" {
    const allocator = testing.allocator;

    const pattern = "(*UCP)\\d";
    const input = "༢"; // Single Tibetan digit

    std.debug.print("\n=== Debug Tibetan Digit Matching ===\n", .{});
    std.debug.print("Pattern: {s}\n", .{pattern});
    std.debug.print("Input: {s}\n", .{input});
    std.debug.print("Input codepoint: U+{X:0>4}\n", .{0x0F22});

    var re = try regex.Regex.compile(allocator, pattern);
    defer re.deinit();

    std.debug.print("Regex compiled, unicode flag: {}\n", .{re.flags.unicode});

    const result = try re.isMatch(input);
    std.debug.print("Match result: {}\n", .{result});

    try testing.expect(result);
}
