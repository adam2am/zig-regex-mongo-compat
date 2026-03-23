const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Simple Regex Benchmarks ===\n\n", .{});

    // Test 1: Literal matching
    {
        std.debug.print("Test 1: Literal matching...\n", .{});
        var regex = try Regex.compile(allocator, "hello");
        defer regex.deinit();

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch("hello world");
        }

        std.debug.print("  {d} iterations completed\n\n", .{iterations});
    }

    // Test 2: Quantifiers
    {
        std.debug.print("Test 2: Quantifiers (a+)...\n", .{});
        var regex = try Regex.compile(allocator, "a+");
        defer regex.deinit();

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch("aaaa");
        }

        std.debug.print("  {d} iterations completed\n\n", .{iterations});
    }

    // Test 3: Character classes
    {
        std.debug.print("Test 3: Digit matching (\\d+)...\n", .{});
        var regex = try Regex.compile(allocator, "\\d+");
        defer regex.deinit();

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch("12345");
        }

        std.debug.print("  {d} iterations completed\n\n", .{iterations});
    }

    // Test 4: Case-insensitive
    {
        std.debug.print("Test 4: Case-insensitive matching...\n", .{});
        var regex = try Regex.compileWithFlags(allocator, "hello", .{ .case_insensitive = true });
        defer regex.deinit();

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch("HELLO");
        }

        std.debug.print("  {d} iterations completed\n\n", .{iterations});
    }

    std.debug.print("=== Benchmarks Complete ===\n", .{});
}
