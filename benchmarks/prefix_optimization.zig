const std = @import("std");
const Regex = @import("regex").Regex;

fn printPrefix(prefix: []const u21) void {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    for (prefix) |codepoint| {
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch continue;
        fbs.writer().writeAll(utf8_buf[0..len]) catch continue;
    }
    std.debug.print("  ✓ Using literal prefix: \"{s}\"\n", .{fbs.getWritten()});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Literal Prefix Optimization Benchmarks ===\n\n", .{});

    // Create a long text where the pattern appears at the end
    const long_text = "The quick brown fox jumps over the lazy dog. " ** 100 ++ "FOUND_IT!";

    // Test 1: Pattern with literal prefix (should use optimization)
    {
        std.debug.print("Test 1: Literal prefix optimization (FOUND_IT!)...\n", .{});
        var regex = try Regex.compile(allocator, "FOUND_IT!");
        defer regex.deinit();

        if (regex.opt_info.literal_prefix) |prefix| {
            printPrefix(prefix);
        } else {
            std.debug.print("  ✗ No literal prefix found\n", .{});
        }

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            if (try regex.find(long_text)) |match| {
                var mut_match = match;
                mut_match.deinit(allocator);
            }
        }

        std.debug.print("  {d} iterations completed\n\n", .{iterations});
    }

    // Test 2: Pattern without useful prefix (no optimization)
    {
        std.debug.print("Test 2: No prefix optimization (.*FOUND)...\n", .{});
        var regex = try Regex.compile(allocator, ".*FOUND");
        defer regex.deinit();

        if (regex.opt_info.literal_prefix) |prefix| {
            printPrefix(prefix);
        } else {
            std.debug.print("  ✗ No literal prefix found (slower performance expected)\n", .{});
        }

        const iterations: usize = 100;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            if (try regex.find(long_text)) |match| {
                var mut_match = match;
                mut_match.deinit(allocator);
            }
        }

        std.debug.print("  {d} iterations completed\n\n", .{iterations});
    }

    // Test 3: Pattern with prefix that allows skipping ahead
    {
        std.debug.print("Test 3: Prefix with complex suffix (hello.*world)...\n", .{});
        const text_with_hello = "blah blah " ** 50 ++ "hello there world";
        var regex = try Regex.compile(allocator, "hello.*world");
        defer regex.deinit();

        if (regex.opt_info.literal_prefix) |prefix| {
            printPrefix(prefix);
        } else {
            std.debug.print("  ✗ No literal prefix found\n", .{});
        }

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            if (try regex.find(text_with_hello)) |match| {
                var mut_match = match;
                mut_match.deinit(allocator);
            }
        }

        std.debug.print("  {d} iterations completed\n\n", .{iterations});
    }

    // Test 4: Anchored patterns
    {
        std.debug.print("Test 4: Start-anchored pattern (^hello)...\n", .{});
        var regex = try Regex.compile(allocator, "^hello");
        defer regex.deinit();

        if (regex.opt_info.anchored_start) {
            std.debug.print("  ✓ Pattern is start-anchored\n", .{});
        }
        if (regex.opt_info.literal_prefix) |prefix| {
            printPrefix(prefix);
        }

        const text = "hello world";
        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try regex.isMatch(text);
        }

        std.debug.print("  {d} iterations completed\n\n", .{iterations});
    }

    // Test 5: Email-like pattern with literal prefix
    {
        std.debug.print("Test 5: Email pattern (user@example.com)...\n", .{});
        const email_text = "Contact us at " ++ ("some filler text here. " ** 20) ++ "user@example.com for support";
        var regex = try Regex.compile(allocator, "user@example.com");
        defer regex.deinit();

        if (regex.opt_info.literal_prefix) |prefix| {
            var buf: [1024]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            for (prefix) |codepoint| {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch continue;
                fbs.writer().writeAll(utf8_buf[0..len]) catch continue;
            }
            std.debug.print("  ✓ Using literal prefix: \"{s}\" (min_len={d})\n", .{ fbs.getWritten(), regex.opt_info.min_length });
        }

        const iterations: usize = 10000;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            if (try regex.find(email_text)) |match| {
                var mut_match = match;
                mut_match.deinit(allocator);
            }
        }

        std.debug.print("  {d} iterations completed\n\n", .{iterations});
    }

    std.debug.print("=== Benchmarks Complete ===\n", .{});
    std.debug.print("\nNote: Patterns with literal prefixes should show significantly\n", .{});
    std.debug.print("better performance when searching in long text, especially when\n", .{});
    std.debug.print("the match appears late in the input.\n", .{});
}
