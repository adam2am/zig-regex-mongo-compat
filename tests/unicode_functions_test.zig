const std = @import("std");
const regex = @import("regex");
const testing = std.testing;

// Direct test of Unicode functions - no regex parsing
test "isDigit - ASCII digits" {
    try testing.expect(regex.unicode.isDigit('0'));
    try testing.expect(regex.unicode.isDigit('5'));
    try testing.expect(regex.unicode.isDigit('9'));
    try testing.expect(!regex.unicode.isDigit('a'));
    try testing.expect(!regex.unicode.isDigit('A'));
}

test "isDigit - Tibetan digits" {
    // Tibetan digits: ༠ ༡ ༢ ༣ ༤ ༥ ༦ ༧ ༨ ༩
    // U+0F20 to U+0F29
    try testing.expect(regex.unicode.isDigit(0x0F20)); // ༠
    try testing.expect(regex.unicode.isDigit(0x0F22)); // ༢
    try testing.expect(regex.unicode.isDigit(0x0F23)); // ༣
    try testing.expect(regex.unicode.isDigit(0x0F24)); // ༤
    try testing.expect(regex.unicode.isDigit(0x0F25)); // ༥
}

test "isLetter - ASCII letters" {
    try testing.expect(regex.unicode.isLetter('a'));
    try testing.expect(regex.unicode.isLetter('Z'));
    try testing.expect(!regex.unicode.isLetter('0'));
    try testing.expect(!regex.unicode.isLetter('9'));
}

test "isLetter - Unicode letters" {
    // é = U+00E9 (Latin Small Letter E with Acute)
    try testing.expect(regex.unicode.isLetter(0x00E9));

    // Ö = U+00D6 (Latin Capital Letter O with Diaeresis)
    try testing.expect(regex.unicode.isLetter(0x00D6));

    // café
    try testing.expect(regex.unicode.isLetter('c'));
    try testing.expect(regex.unicode.isLetter('a'));
    try testing.expect(regex.unicode.isLetter('f'));
    try testing.expect(regex.unicode.isLetter(0x00E9)); // é
}

test "CharClass with unicode_property - digit" {
    const char_class = regex.common.CharClass.initWithProperty(.digit, false);

    // ASCII digits
    try testing.expect(char_class.matches('0'));
    try testing.expect(char_class.matches('5'));
    try testing.expect(char_class.matches('9'));

    // Tibetan digits
    try testing.expect(char_class.matches(0x0F22)); // ༢
    try testing.expect(char_class.matches(0x0F25)); // ༥

    // Non-digits
    try testing.expect(!char_class.matches('a'));
    try testing.expect(!char_class.matches('Z'));
}

test "CharClass with unicode_property - letter" {
    const char_class = regex.common.CharClass.initWithProperty(.letter, false);

    // ASCII letters
    try testing.expect(char_class.matches('a'));
    try testing.expect(char_class.matches('Z'));

    // Unicode letters
    try testing.expect(char_class.matches(0x00E9)); // é
    try testing.expect(char_class.matches(0x00D6)); // Ö

    // Non-letters
    try testing.expect(!char_class.matches('0'));
    try testing.expect(!char_class.matches('9'));
}
