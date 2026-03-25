const std = @import("std");
const Regex = @import("regex").Regex;

test "\\X: matches basic ASCII character" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\X$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("ab")); // Two graphemes
}

test "\\X: matches precomposed unicode character" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\X$");
    defer regex.deinit();

    // 'é' (U+00E9)
    try std.testing.expect(try regex.isMatch("é"));
}

test "\\X: matches decomposed combining marks as a single grapheme" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\X$");
    defer regex.deinit();

    // 'e' (U+0065) + combining acute accent (U+0301)
    const decomposed = "e\u{0301}";
    try std.testing.expect(try regex.isMatch(decomposed));
}

test "\\X: matches ZWJ emoji sequences (Family)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\X$");
    defer regex.deinit();

    // Man + ZWJ + Woman + ZWJ + Girl (👨‍👩‍👧)
    const family_emoji = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    try std.testing.expect(try regex.isMatch(family_emoji));
}

test "\\X: matches Regional Indicator sequences (Flags)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\X$");
    defer regex.deinit();

    // US Flag (U+1F1FA + U+1F1F8)
    const us_flag = "\u{1F1FA}\u{1F1F8}";
    try std.testing.expect(try regex.isMatch(us_flag));
}

test "\\X: properly handles sequences of regional indicators (even/odd rule)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\X\\X$"); // Expects EXACTLY TWO graphemes
    defer regex.deinit();

    // Three regional indicators should be parsed as: [RI, RI] (Flag 1) + RI (Standalone RI)
    // Therefore it is exactly TWO graphemes!
    const three_ris = "\u{1F1FA}\u{1F1F8}\u{1F1E8}"; // US Flag + 'C' regional indicator
    try std.testing.expect(try regex.isMatch(three_ris));
}

test "\\X: extracting graphemes from string" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\X");
    defer regex.deinit();

    // café with decomposed 'é'
    const input = "cafe\u{0301}";
    const matches = try regex.findAll(allocator, input);
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 4), matches.len);
    try std.testing.expectEqualStrings("c", matches[0].slice);
    try std.testing.expectEqualStrings("a", matches[1].slice);
    try std.testing.expectEqualStrings("f", matches[2].slice);
    try std.testing.expectEqualStrings("e\u{0301}", matches[3].slice);
}

test "\\X: failure at end of string" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a\\X");
    defer regex.deinit();

    // Should not match since there is no grapheme after 'a'
    try std.testing.expect(!try regex.isMatch("a"));
}

test "\\X: handling invalid UTF-8 gracefully" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\X");
    defer regex.deinit();

    // Truncated UTF-8 should silently fail to match \X (or fall back depending on engine rules)
    const invalid_utf8 = "\xE0\x80";
    try std.testing.expect(!try regex.isMatch(invalid_utf8));
}
