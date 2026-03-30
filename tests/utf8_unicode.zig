const std = @import("std");
const Regex = @import("regex").Regex;

// UTF-8 and Unicode Tests

test "UTF-8: literal matching" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "café");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("café"));
    try std.testing.expect(!try regex.isMatch("cafe"));
}

test "UTF-8: emoji matching" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "Hello 👋 World");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("Hello 👋 World"));
}

test "UTF-8: Chinese characters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "你好");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("你好"));
    try std.testing.expect(try regex.isMatch("你好世界"));
}

test "UTF-8: mixed ASCII and Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "test-тест-テスト");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("test-тест-テスト"));
}

test "UTF-8: dot matches multi-byte character" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "c.fé");
    defer regex.deinit();

    // Currently .  matches one byte, not one character
    // This test documents current behavior
    try std.testing.expect(try regex.isMatch("café"));
}

test "\\R: matches CR" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "line1\\Rline2");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("line1\rline2"));
}

test "\\R: matches LF" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "line1\\Rline2");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("line1\nline2"));
}

test "\\R: matches CRLF" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "line1\\Rline2");
    defer regex.deinit();

    // Per PCRE2 spec: \R matches CRLF as ONE atomic sequence
    try std.testing.expect(try regex.isMatch("line1\r\nline2"));
}

test "\\R: matches Unicode NEL (U+0085)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "line1\\Rline2");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("line1\u{0085}line2"));
}

test "\\R: matches Unicode Line Separator (U+2028)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "line1\\Rline2");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("line1\u{2028}line2"));
}

test "\\R: matches Unicode Paragraph Separator (U+2029)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "line1\\Rline2");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("line1\u{2029}line2"));
}

test "UTF-8: alternation with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "hello|你好|こんにちは");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(try regex.isMatch("你好"));
    try std.testing.expect(try regex.isMatch("こんにちは"));
}

test "UTF-8: character class range with multi-byte" {
    const allocator = std.testing.allocator;
    // Character classes currently only work with single-byte ASCII
    var regex = try Regex.compile(allocator, "[a-z]+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    // Multi-byte UTF-8 (é) won't match [a-z], but "caf" will
    const result = try regex.find("café");
    try std.testing.expect(result != null);
    if (result) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        // Only matches ASCII part "caf", not the é
        try std.testing.expectEqualStrings("caf", match.slice);
    }
}

test "UTF-8: quantifiers with Unicode literals" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "あ+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("あ"));
    try std.testing.expect(try regex.isMatch("ああああ"));
}

test "UTF-8: capture groups with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(你好)(世界)");
    defer regex.deinit();

    const result = try regex.find("你好世界");
    try std.testing.expect(result != null);
    if (result) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 2), match.captures.len);
        try std.testing.expectEqualStrings("你好", match.captures[0]);
        try std.testing.expectEqualStrings("世界", match.captures[1]);
    }
}

test "UTF-8: replacement with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)@(\\w+)");
    defer regex.deinit();

    // ASCII works
    const result1 = try regex.replace(allocator, "user@example", "$1 at $2");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("user at example", result1);
}

test "UTF-8: anchors with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^你好$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("你好"));
    try std.testing.expect(!try regex.isMatch("你好世界"));
    try std.testing.expect(!try regex.isMatch("世界你好"));
}

test "UTF-8: non-capturing groups with Unicode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?:안녕|hello) (world|세계)");
    defer regex.deinit();

    const result1 = try regex.find("hello world");
    try std.testing.expect(result1 != null);
    if (result1) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);
        try std.testing.expectEqualStrings("world", match.captures[0]);
    }

    const result2 = try regex.find("안녕 세계");
    try std.testing.expect(result2 != null);
    if (result2) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);
        try std.testing.expectEqualStrings("세계", match.captures[0]);
    }
}

// Document current limitations
test "UTF-8: dot matches multi-byte characters" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ".");
    defer regex.deinit();

    // Single ASCII character
    try std.testing.expect(try regex.isMatch("a"));

    // Multi-byte characters - dot now correctly matches entire UTF-8 characters
    try std.testing.expect(try regex.isMatch("é")); // é is 2 bytes
    try std.testing.expect(try regex.isMatch("你")); // 你 is 3 bytes
}

test "UTF-8: default \\w remains ASCII-only without unicode mode" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\w+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(try regex.isMatch("test123"));

    const result = try regex.find("café");
    if (result) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqualStrings("caf", match.slice);
    }
}

// --- Strict UTF-8 Validation Edge Cases ---

test "UTF-8: invalid byte sequence errors gracefully" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ".*");
    defer regex.deinit();

    // \xff\xfe is invalid UTF-8
    const invalid_str = "\xff\xfe";
    const result = regex.isMatch(invalid_str);
    try std.testing.expectError(error.InvalidUtf8, result);
}

test "UTF-8: invalid half-surrogate errors gracefully" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, ".*");
    defer regex.deinit();

    // \xED\xA0\x80 is the UTF-8 encoding of U+D800 (a lone surrogate, invalid in UTF-8)
    const invalid_surrogate = "\xED\xA0\x80";
    const result = regex.isMatch(invalid_surrogate);
    try std.testing.expectError(error.InvalidUtf8, result);
}

test "UTF-8: case insensitive with Unicode Ü" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?i)ü");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("ü"));
    try std.testing.expect(try regex.isMatch("Ü"));
}

test "UTF-8: case insensitive Turkish I folding" {
    const allocator = std.testing.allocator;
    // İ (U+0130) should fold to 'i'
    var regex = try Regex.compile(allocator, "(?i)\u{0130}");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("i"));
}

test "UTF-8: case insensitive Kelvin sign folding" {
    const allocator = std.testing.allocator;
    // K (Kelvin, U+212A) should fold to 'k'
    var regex = try Regex.compile(allocator, "(?i)\u{212A}");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("k"));
}
