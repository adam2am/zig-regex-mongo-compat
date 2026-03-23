const std = @import("std");
const regex = @import("regex");

test "\\Q...\\E literal sequences" {
    const allocator = std.testing.allocator;

    // Test 1: Basic literal sequence
    {
        const compiled = try regex.compile(allocator, "\\Q.*+?\\E", .{});
        defer compiled.deinit();

        try std.testing.expect(try compiled.isMatch(".*+?"));
        try std.testing.expect(!try compiled.isMatch("abc"));
    }

    // Test 2: Literal sequence with special chars
    {
        const compiled = try regex.compile(allocator, "\\Q[a-z]+\\E", .{});
        defer compiled.deinit();

        try std.testing.expect(try compiled.isMatch("[a-z]+"));
        try std.testing.expect(!try compiled.isMatch("abc"));
    }

    // Test 3: Mixed literal and regex
    {
        const compiled = try regex.compile(allocator, "a\\Q.*\\Eb", .{});
        defer compiled.deinit();

        try std.testing.expect(try compiled.isMatch("a.*b"));
        try std.testing.expect(!try compiled.isMatch("aXXXb"));
    }

    // Test 4: Empty literal sequence
    {
        const compiled = try regex.compile(allocator, "\\Q\\E", .{});
        defer compiled.deinit();

        try std.testing.expect(try compiled.isMatch(""));
    }

    // Test 5: Literal backslash
    {
        const compiled = try regex.compile(allocator, "\\Q\\\\E", .{});
        defer compiled.deinit();

        try std.testing.expect(try compiled.isMatch("\\"));
    }

    // Test 6: Multiple literal sequences
    {
        const compiled = try regex.compile(allocator, "\\Q.*\\E.\\Q+?\\E", .{});
        defer compiled.deinit();

        try std.testing.expect(try compiled.isMatch(".*X+?"));
        try std.testing.expect(!try compiled.isMatch(".*+?"));
    }
}
