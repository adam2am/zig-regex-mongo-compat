const std = @import("std");
const unicode_tables = @import("unicode_tables.zig");
const Regex = @import("regex.zig").Regex;

test "Unicode word char detection for Ö (U+00D6)" {
    const o_with_diaeresis: u21 = 0xD6; // Ö

    // Test ASCII mode
    const is_word_ascii = unicode_tables.isWordChar(o_with_diaeresis, false);
    std.debug.print("\nÖ (U+00D6) is word char in ASCII mode: {}\n", .{is_word_ascii});

    // Test Unicode mode
    const is_word_unicode = unicode_tables.isWordChar(o_with_diaeresis, true);
    std.debug.print("Ö (U+00D6) is word char in Unicode mode: {}\n", .{is_word_unicode});

    try std.testing.expect(is_word_unicode == true);
}

test "(*UCP)\\bÖyster pattern matching" {
    const allocator = std.testing.allocator;

    const pattern = "(*UCP)\\bÖyster";
    const input = "Öyster";

    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();

    const result = try regex.isMatch(input);
    std.debug.print("\nPattern: {s}\n", .{pattern});
    std.debug.print("Input: {s}\n", .{input});
    std.debug.print("Match result: {}\n", .{result});

    try std.testing.expect(result == true);
}

test "Word boundary at start of Öyster" {
    const allocator = std.testing.allocator;

    const pattern = "(*UCP)\\b";
    const input = "Öyster";

    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();

    const result = try regex.isMatch(input);
    std.debug.print("\nPattern: {s}\n", .{pattern});
    std.debug.print("Input: {s}\n", .{input});
    std.debug.print("\\b matches at start: {}\n", .{result});

    try std.testing.expect(result == true);
}
