const std = @import("std");
const Regex = @import("src/root.zig").Regex;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Testing inline modifier (?i) ===\n\n", .{});

    // Happy path 1: Simple (?i)
    std.debug.print("Test 1: a(?i)bc on 'aBC'\n", .{});
    var regex1 = Regex.compile(allocator, "a(?i)bc") catch |err| {
        std.debug.print("  ❌ ERROR compiling: {}\n\n", .{err});
        return;
    };
    defer regex1.deinit();

    const result1 = regex1.isMatch("aBC") catch |err| {
        std.debug.print("  ❌ ERROR matching: {}\n\n", .{err});
        return;
    };
    std.debug.print("  Result: {}\n", .{result1});
    std.debug.print("  Expected: true\n", .{});
    std.debug.print("  Status: {s}\n\n", .{if (result1) "✅ PASS" else "❌ FAIL"});

    // Happy path 2: Scoped (?i:...)
    std.debug.print("Test 2: a(?i:bc)d on 'aBCd'\n", .{});
    var regex2 = Regex.compile(allocator, "a(?i:bc)d") catch |err| {
        std.debug.print("  ❌ ERROR compiling: {}\n\n", .{err});
        return;
    };
    defer regex2.deinit();

    const result2 = regex2.isMatch("aBCd") catch |err| {
        std.debug.print("  ❌ ERROR matching: {}\n\n", .{err});
        return;
    };
    std.debug.print("  Result: {}\n", .{result2});
    std.debug.print("  Expected: true\n", .{});
    std.debug.print("  Status: {s}\n\n", .{if (result2) "✅ PASS" else "❌ FAIL"});

    // Unhappy path 1: Should NOT match (case-sensitive 'a')
    std.debug.print("Test 3: a(?i)bc on 'ABC' (should NOT match)\n", .{});
    var regex3 = Regex.compile(allocator, "a(?i)bc") catch |err| {
        std.debug.print("  ❌ ERROR compiling: {}\n\n", .{err});
        return;
    };
    defer regex3.deinit();

    const result3 = regex3.isMatch("ABC") catch |err| {
        std.debug.print("  ❌ ERROR matching: {}\n\n", .{err});
        return;
    };
    std.debug.print("  Result: {}\n", .{result3});
    std.debug.print("  Expected: false\n", .{});
    std.debug.print("  Status: {s}\n\n", .{if (!result3) "✅ PASS" else "❌ FAIL"});

    // Unhappy path 2: Scoped - 'd' should be case-sensitive
    std.debug.print("Test 4: a(?i:bc)d on 'aBCD' (should NOT match)\n", .{});
    var regex4 = Regex.compile(allocator, "a(?i:bc)d") catch |err| {
        std.debug.print("  ❌ ERROR compiling: {}\n\n", .{err});
        return;
    };
    defer regex4.deinit();

    const result4 = regex4.isMatch("aBCD") catch |err| {
        std.debug.print("  ❌ ERROR matching: {}\n\n", .{err});
        return;
    };
    std.debug.print("  Result: {}\n", .{result4});
    std.debug.print("  Expected: false\n", .{});
    std.debug.print("  Status: {s}\n\n", .{if (!result4) "✅ PASS" else "❌ FAIL"});

    // Edge case: Multiple modifiers
    std.debug.print("Test 5: (?im)^test$ on 'TEST' with multiline\n", .{});
    var regex5 = Regex.compile(allocator, "(?im)^test$") catch |err| {
        std.debug.print("  ❌ ERROR compiling: {}\n\n", .{err});
        return;
    };
    defer regex5.deinit();

    const result5 = regex5.isMatch("TEST") catch |err| {
        std.debug.print("  ❌ ERROR matching: {}\n\n", .{err});
        return;
    };
    std.debug.print("  Result: {}\n", .{result5});
    std.debug.print("  Expected: true\n", .{});
    std.debug.print("  Status: {s}\n\n", .{if (result5) "✅ PASS" else "❌ FAIL"});
}
