const std = @import("std");
const Regex = @import("regex").Regex;

/// Simplified advanced features example
/// Demonstrates key features without importing heavy modules that cause OOM during compilation
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Advanced Regex Features (Simplified) ===\n\n", .{});

    // Example 1: Case-insensitive matching
    {
        std.debug.print("Example 1: Case-insensitive matching\n", .{});
        var regex = try Regex.compileWithFlags(allocator, "hello", .{ .case_insensitive = true });
        defer regex.deinit();

        const test_cases = [_][]const u8{ "HELLO", "Hello", "hello", "HeLLo" };
        for (test_cases) |text| {
            const matches = try regex.isMatch(text);
            std.debug.print("  '{s}' matches: {}\n", .{ text, matches });
        }
        std.debug.print("\n", .{});
    }

    // Example 2: Multiline mode
    {
        std.debug.print("Example 2: Multiline mode (^ and $ match line boundaries)\n", .{});
        var regex = try Regex.compileWithFlags(allocator, "^test$", .{ .multiline = true });
        defer regex.deinit();

        const text = "line1\ntest\nline3";
        const matches = try regex.isMatch(text);
        std.debug.print("  Pattern '^test$' in multiline text: {}\n\n", .{matches});
    }

    // Example 3: Dot-all mode
    {
        std.debug.print("Example 3: Dot-all mode (. matches newlines)\n", .{});
        var regex = try Regex.compileWithFlags(allocator, "a.b", .{ .dot_all = true });
        defer regex.deinit();

        const text = "a\nb";
        const matches = try regex.isMatch(text);
        std.debug.print("  Pattern 'a.b' matches 'a\\nb': {}\n\n", .{matches});
    }

    // Example 4: Unicode support
    {
        std.debug.print("Example 4: Unicode matching\n", .{});
        var regex = try Regex.compile(allocator, "café");
        defer regex.deinit();

        const matches = try regex.isMatch("I love café");
        std.debug.print("  Pattern 'café' matches: {}\n\n", .{matches});
    }

    // Example 5: Anchors
    {
        std.debug.print("Example 5: Start and end anchors\n", .{});
        var start_regex = try Regex.compile(allocator, "^hello");
        defer start_regex.deinit();
        var end_regex = try Regex.compile(allocator, "world$");
        defer end_regex.deinit();

        const text = "hello world";
        const starts = try start_regex.isMatch(text);
        const ends = try end_regex.isMatch(text);
        std.debug.print("  '^hello' matches: {}\n", .{starts});
        std.debug.print("  'world$' matches: {}\n\n", .{ends});
    }

    // Example 6: Character classes
    {
        std.debug.print("Example 6: Character classes\n", .{});
        var digit_regex = try Regex.compile(allocator, "\\d+");
        defer digit_regex.deinit();
        var word_regex = try Regex.compile(allocator, "\\w+");
        defer word_regex.deinit();

        const text = "abc123";
        if (try digit_regex.find(text)) |match| {
            std.debug.print("  Digits found: {s}\n", .{match.slice});
        }
        if (try word_regex.find(text)) |match| {
            std.debug.print("  Word found: {s}\n", .{match.slice});
        }
        std.debug.print("\n", .{});
    }

    // Example 7: Quantifiers
    {
        std.debug.print("Example 7: Greedy vs non-greedy quantifiers\n", .{});
        var greedy = try Regex.compile(allocator, "a+");
        defer greedy.deinit();
        var lazy = try Regex.compile(allocator, "a+?");
        defer lazy.deinit();

        const text = "aaaa";
        if (try greedy.find(text)) |match| {
            std.debug.print("  Greedy 'a+': {s} (length: {})\n", .{ match.slice, match.slice.len });
        }
        if (try lazy.find(text)) |match| {
            std.debug.print("  Lazy 'a+?': {s} (length: {})\n", .{ match.slice, match.slice.len });
        }
        std.debug.print("\n", .{});
    }

    // Example 8: Alternation
    {
        std.debug.print("Example 8: Alternation (OR)\n", .{});
        var regex = try Regex.compile(allocator, "cat|dog|bird");
        defer regex.deinit();

        const test_cases = [_][]const u8{ "I have a cat", "I have a dog", "I have a bird", "I have a fish" };
        for (test_cases) |text| {
            const matches = try regex.isMatch(text);
            std.debug.print("  '{s}': {}\n", .{ text, matches });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("=== Examples Complete ===\n", .{});
}
