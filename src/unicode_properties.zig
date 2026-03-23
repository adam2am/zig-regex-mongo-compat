const std = @import("std");

/// Unicode script identifiers
/// Using range-based matching (production-proven approach)
/// Only scripts with defined ranges are included
pub const Script = enum {
    Latin,
    Greek,
    Cyrillic,
    // TODO: Add ranges for additional scripts as needed:
    // Arabic, Hebrew, Han, Hiragana, Katakana, etc.
};

/// Character ranges for each script (from Unicode Character Database)
/// Format: array of (start, end) inclusive ranges
const LATIN_RANGES = [_]struct { u21, u21 }{
    .{ 0x0041, 0x005A }, // A-Z
    .{ 0x0061, 0x007A }, // a-z
    .{ 0x00AA, 0x00AA }, // ª
    .{ 0x00BA, 0x00BA }, // º
    .{ 0x00C0, 0x00D6 }, // À-Ö
    .{ 0x00D8, 0x00F6 }, // Ø-ö
    .{ 0x00F8, 0x02B8 }, // ø-ʸ
    .{ 0x02E0, 0x02E4 }, // ˠ-ˤ
    .{ 0x1D00, 0x1D25 }, // ᴀ-ᴥ
    .{ 0x1D2C, 0x1D5C }, // ᴬ-ᵜ
    .{ 0x1D62, 0x1D65 }, // ᵢ-ᵥ
    .{ 0x1D6B, 0x1D77 }, // ᵫ-ᵷ
    .{ 0x1D79, 0x1DBE }, // ᵹ-ᶾ
    .{ 0x1E00, 0x1EFF }, // Ḁ-ỿ
    .{ 0x2071, 0x2071 }, // ⁱ
    .{ 0x207F, 0x207F }, // ⁿ
    .{ 0x2090, 0x209C }, // ₐ-ₜ
    .{ 0x212A, 0x212B }, // K-Å
    .{ 0x2132, 0x2132 }, // Ⅎ
    .{ 0x214E, 0x214E }, // ⅎ
    .{ 0x2160, 0x2188 }, // Ⅰ-ↈ
    .{ 0x2C60, 0x2C7F }, // Ⱡ-Ɀ
    .{ 0xA722, 0xA787 }, // Ꜣ-ꞇ
    .{ 0xA78B, 0xA7CA }, // Ꞌ-ꟊ
    .{ 0xA7D0, 0xA7D1 }, // Ꟑ-ꟑ
    .{ 0xA7D3, 0xA7D3 }, // ꟓ
    .{ 0xA7D5, 0xA7D9 }, // ꟕ-ꟙ
    .{ 0xAB30, 0xAB5A }, // ꬰ-ꭚ
    .{ 0xAB5C, 0xAB64 }, // ꭜ-ꭤ
    .{ 0xAB65, 0xAB69 }, // ꭥ-ꭩ
    .{ 0xFB00, 0xFB06 }, // ﬀ-ﬆ
    .{ 0xFF21, 0xFF3A }, // Ａ-Ｚ
    .{ 0xFF41, 0xFF5A }, // ａ-ｚ
};

const GREEK_RANGES = [_]struct { u21, u21 }{
    .{ 0x0370, 0x0373 }, // Ͱ-ͳ
    .{ 0x0375, 0x0377 }, // ͵-ͷ
    .{ 0x037A, 0x037D }, // ͺ-ͽ
    .{ 0x037F, 0x037F }, // Ϳ
    .{ 0x0384, 0x0385 }, // ΄-΅
    .{ 0x0386, 0x0386 }, // Ά
    .{ 0x0388, 0x038A }, // Έ-Ί
    .{ 0x038C, 0x038C }, // Ό
    .{ 0x038E, 0x03A1 }, // Ύ-Ρ
    .{ 0x03A3, 0x03FF }, // Σ-Ͽ
    .{ 0x1D26, 0x1D2A }, // ᴦ-ᴪ
    .{ 0x1D5D, 0x1D61 }, // ᵝ-ᵡ
    .{ 0x1D66, 0x1D6A }, // ᵦ-ᵪ
    .{ 0x1DBF, 0x1DBF }, // ᶿ
    .{ 0x1F00, 0x1F15 }, // ἀ-ἕ
    .{ 0x1F18, 0x1F1D }, // Ἐ-Ἕ
    .{ 0x1F20, 0x1F45 }, // ἠ-ὅ
    .{ 0x1F48, 0x1F4D }, // Ὀ-Ὅ
    .{ 0x1F50, 0x1F57 }, // ὐ-ὗ
    .{ 0x1F59, 0x1F59 }, // Ὑ
    .{ 0x1F5B, 0x1F5B }, // Ὓ
    .{ 0x1F5D, 0x1F5D }, // Ὕ
    .{ 0x1F5F, 0x1F7D }, // Ὗ-ώ
    .{ 0x1F80, 0x1FB4 }, // ᾀ-ᾴ
    .{ 0x1FB6, 0x1FC4 }, // ᾶ-ῄ
    .{ 0x1FC6, 0x1FD3 }, // ῆ-ΐ
    .{ 0x1FD6, 0x1FDB }, // ῖ-Ί
    .{ 0x1FDD, 0x1FEF }, // ῝-`
    .{ 0x1FF2, 0x1FF4 }, // ῲ-ῴ
    .{ 0x1FF6, 0x1FFE }, // ῶ-῾
    .{ 0x2126, 0x2126 }, // Ω
};

const CYRILLIC_RANGES = [_]struct { u21, u21 }{
    .{ 0x0400, 0x0484 }, // Ѐ-҄
    .{ 0x0487, 0x052F }, // ҇-ԯ
    .{ 0x1C80, 0x1C88 }, // ᲀ-ᲈ
    .{ 0x1D2B, 0x1D2B }, // ᴫ
    .{ 0x1D78, 0x1D78 }, // ᵸ
    .{ 0x2DE0, 0x2DFF }, // ⷠ-ⷿ
    .{ 0xA640, 0xA69F }, // Ꙁ-ꚟ
    .{ 0xFE2E, 0xFE2F }, // ︮-︯
};

/// Compile-time map from script name to Script enum
pub const SCRIPT_BY_NAME = std.StaticStringMap(Script).initComptime(.{
    .{ "Latin", .Latin },
    .{ "Greek", .Greek },
    .{ "Cyrillic", .Cyrillic },
});

/// Check if a codepoint belongs to a specific script
/// Uses linear search over ranges (O(n) - acceptable for small range counts)
pub fn matchesScript(cp: u21, script: Script) bool {
    const ranges = switch (script) {
        .Latin => &LATIN_RANGES,
        .Greek => &GREEK_RANGES,
        .Cyrillic => &CYRILLIC_RANGES,
        // Exhaustive switch - compiler will error if enum values added without ranges
    };

    // Linear search over ranges (O(n) where n = number of ranges per script)
    // For Latin: 33 ranges, Greek: 32 ranges, Cyrillic: 8 ranges
    // Could optimize to binary search if performance becomes an issue
    for (ranges) |range| {
        if (cp >= range[0] and cp <= range[1]) {
            return true;
        }
    }
    return false;
}
