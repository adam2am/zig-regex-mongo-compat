const std = @import("std");
const regex = @import("regex");
const testing = std.testing;

test "Debug: POSIX class token sequence" {
    const allocator = testing.allocator;

    const pattern = "[[:alpha:]]";

    std.debug.print("\n=== Debug POSIX Class Parsing ===\n", .{});
    std.debug.print("Pattern: {s}\n", .{pattern});

    var re = regex.Regex.compile(allocator, pattern) catch |err| {
        std.debug.print("Compilation failed with error: {}\n", .{err});
        return err;
    };
    defer re.deinit();

    std.debug.print("Pattern compiled successfully!\n", .{});
}

test "Debug: POSIX class with UCP" {
    const allocator = testing.allocator;

    const pattern = "(*UCP)[[:alpha:]]+";
    const input = "café";

    std.debug.print("\n=== Debug POSIX Class with UCP ===\n", .{});
    std.debug.print("Pattern: {s}\n", .{pattern});
    std.debug.print("Input: {s}\n", .{input});

    var re = regex.Regex.compile(allocator, pattern) catch |err| {
        std.debug.print("Compilation failed with error: {}\n", .{err});
        return err;
    };
    defer re.deinit();

    const result = try re.isMatch(input);
    std.debug.print("Match result: {}\n", .{result});

    try testing.expect(result);
}
