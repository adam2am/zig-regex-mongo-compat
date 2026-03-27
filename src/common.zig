const std = @import("std");

/// 256-bit set for O(1) ASCII and Latin-1 character class lookups
pub const FastBitSet = struct {
    bits: [4]u64 = .{ 0, 0, 0, 0 },

    pub inline fn set(self: *FastBitSet, c: u8) void {
        self.bits[c >> 6] |= (@as(u64, 1) << @intCast(c & 63));
    }

    pub inline fn testBit(self: *const FastBitSet, c: u8) bool {
        return (self.bits[c >> 6] & (@as(u64, 1) << @intCast(c & 63))) != 0;
    }
};

/// Character type used throughout the library
/// u21 supports full Unicode codepoints (U+0000 to U+10FFFF)
pub const Char = u21;

/// Position in the input string
pub const Position = usize;

/// Represents a range of characters (for character classes)
pub const CharRange = struct {
    start: Char,
    end: Char,

    pub fn contains(self: CharRange, c: Char) bool {
        return c >= self.start and c <= self.end;
    }

    pub fn init(start: Char, end: Char) CharRange {
        return .{ .start = start, .end = end };
    }
};

/// Character class - represents a set of characters
pub const CharClass = struct {
    ranges: []const CharRange,
    negated: bool = false,
    unicode_property: ?UnicodeProperty = null,
    fast_ascii: FastBitSet = .{},

    pub const UnicodeProperty = union(enum) {
        digit,
        letter,
        alnum,
        any,
        script: Script,

        pub const Script = @import("unicode_properties.zig").Script;
    };

    /// Precomputes the FastBitSet for ASCII/Latin-1 characters (0-255)
    /// Must be called immediately after initialization
    pub fn precompute(self: *CharClass) void {
        for (0..256) |i| {
            const char_val: Char = @intCast(i);
            var is_match = false;

            if (self.unicode_property) |prop| {
                const unicode = @import("unicode.zig");
                const unicode_properties = @import("unicode_properties.zig");
                is_match = switch (prop) {
                    .digit => unicode.isDigit(char_val),
                    .letter => unicode.isLetter(char_val),
                    .alnum => unicode.isAlphanumeric(char_val),
                    .any => true,
                    .script => |s| unicode_properties.matchesScript(char_val, s),
                };
            } else {
                for (self.ranges) |range| {
                    if (range.contains(char_val)) {
                        is_match = true;
                        break;
                    }
                }
            }

            if (is_match) {
                self.fast_ascii.set(@intCast(i));
            }
        }
    }

    pub inline fn matches(self: *const CharClass, c: Char) bool {
        // 1. FAST PATH: O(1) lookup for ASCII / Latin-1
        if (c < 256) {
            const matched = self.fast_ascii.testBit(@intCast(c));
            return if (self.negated) !matched else matched;
        }

        // 2. SLOW PATH: Fallback for larger Unicode codepoints
        if (self.unicode_property) |prop| {
            const unicode = @import("unicode.zig");
            const unicode_properties = @import("unicode_properties.zig");
            const prop_match = switch (prop) {
                .digit => unicode.isDigit(c),
                .letter => unicode.isLetter(c),
                .alnum => unicode.isAlphanumeric(c),
                .any => true,
                .script => |s| unicode_properties.matchesScript(c, s),
            };
            return if (self.negated) !prop_match else prop_match;
        }

        var found = false;
        for (self.ranges) |range| {
            if (range.contains(c)) {
                found = true;
                break;
            }
        }
        return if (self.negated) !found else found;
    }

    /// Initialize from ranges - automatically precomputes FastBitSet
    pub fn init(ranges: []const CharRange, negated: bool) CharClass {
        var cc = CharClass{
            .ranges = ranges,
            .negated = negated,
        };
        cc.precompute();
        return cc;
    }

    /// Initialize with unicode property - automatically precomputes FastBitSet
    pub fn initWithProperty(prop: UnicodeProperty, negated: bool) CharClass {
        var cc = CharClass{
            .ranges = &[_]CharRange{},
            .negated = negated,
            .unicode_property = prop,
        };
        cc.precompute();
        return cc;
    }
};

/// Regex compilation flags
pub const CompileFlags = packed struct {
    case_insensitive: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    extended: bool = false,
    unicode: bool = false,

    /// Parses standard regex string flags (e.g. "imx") into a CompileFlags struct.
    pub fn parse(flags_str: []const u8) !CompileFlags {
        var flags = CompileFlags{};
        for (flags_str) |ch| {
            switch (ch) {
                'i' => flags.case_insensitive = true,
                'm' => flags.multiline = true,
                's' => flags.dot_all = true,
                'x' => flags.extended = true,
                'u' => flags.unicode = true,
                else => return error.InvalidFlags,
            }
        }
        return flags;
    }
};

test "CompileFlags.parse" {
    const flags1 = try CompileFlags.parse("imx");
    try std.testing.expect(flags1.case_insensitive);
    try std.testing.expect(flags1.multiline);
    try std.testing.expect(flags1.extended);
    try std.testing.expect(!flags1.dot_all);
    try std.testing.expect(!flags1.unicode);

    const flags2 = try CompileFlags.parse("su");
    try std.testing.expect(!flags2.case_insensitive);
    try std.testing.expect(flags2.dot_all);
    try std.testing.expect(flags2.unicode);

    try std.testing.expectError(error.InvalidFlags, CompileFlags.parse("imZ"));
}

/// Comptime helper for creating precomputed static CharClasses
/// This computes the FastBitSet at compile time - zero runtime overhead
fn createStaticCharClass(ranges: []const CharRange, negated: bool) CharClass {
    @setEvalBranchQuota(10000);
    var class = CharClass{
        .ranges = ranges,
        .negated = negated,
    };
    class.precompute();
    return class;
}

/// Span in the source pattern (for error reporting)
pub const Span = struct {
    start: Position,
    end: Position,

    pub fn init(start: Position, end: Position) Span {
        return .{ .start = start, .end = end };
    }

    pub fn len(self: Span) usize {
        return self.end - self.start;
    }
};

/// Predefined character classes
pub const CharClasses = struct {
    /// Digits: [0-9]
    pub const digit = createStaticCharClass(&[_]CharRange{
        CharRange.init('0', '9'),
    }, false);

    /// Non-digits: [^0-9]
    pub const non_digit = createStaticCharClass(&[_]CharRange{
        CharRange.init('0', '9'),
    }, true);

    /// Word characters: [a-zA-Z0-9_]
    pub const word = createStaticCharClass(&[_]CharRange{
        CharRange.init('a', 'z'),
        CharRange.init('A', 'Z'),
        CharRange.init('0', '9'),
        CharRange.init('_', '_'),
    }, false);

    /// Non-word characters: [^a-zA-Z0-9_]
    pub const non_word = createStaticCharClass(&[_]CharRange{
        CharRange.init('a', 'z'),
        CharRange.init('A', 'Z'),
        CharRange.init('0', '9'),
        CharRange.init('_', '_'),
    }, true);

    /// Whitespace: [ \t\n\r\f\v]
    pub const whitespace = createStaticCharClass(&[_]CharRange{
        CharRange.init(' ', ' '),
        CharRange.init('\t', '\t'),
        CharRange.init('\n', '\n'),
        CharRange.init('\r', '\r'),
        CharRange.init(0x0C, 0x0C), // \f
        CharRange.init(0x0B, 0x0B), // \v
    }, false);

    /// Non-whitespace: [^ \t\n\r\f\v]
    pub const non_whitespace = createStaticCharClass(&[_]CharRange{
        CharRange.init(' ', ' '),
        CharRange.init('\t', '\t'),
        CharRange.init('\n', '\n'),
        CharRange.init('\r', '\r'),
        CharRange.init(0x0C, 0x0C), // \f
        CharRange.init(0x0B, 0x0B), // \v
    }, true);

    /// Horizontal whitespace: [ \t]
    pub const horizontal_whitespace = createStaticCharClass(&[_]CharRange{
        CharRange.init(' ', ' '),
        CharRange.init('\t', '\t'),
    }, false);

    /// Non-horizontal whitespace: [^ \t]
    pub const non_horizontal_whitespace = createStaticCharClass(&[_]CharRange{
        CharRange.init(' ', ' '),
        CharRange.init('\t', '\t'),
    }, true);

    /// Vertical whitespace: [\n\r\f\v]
    pub const vertical_whitespace = createStaticCharClass(&[_]CharRange{
        CharRange.init('\n', '\n'),
        CharRange.init('\r', '\r'),
        CharRange.init(0x0C, 0x0C), // \f
        CharRange.init(0x0B, 0x0B), // \v
    }, false);

    /// Non-vertical whitespace: [^\n\r\f\v]
    pub const non_vertical_whitespace = createStaticCharClass(&[_]CharRange{
        CharRange.init('\n', '\n'),
        CharRange.init('\r', '\r'),
        CharRange.init(0x0C, 0x0C), // \f
        CharRange.init(0x0B, 0x0B), // \v
    }, true);

    // POSIX Character Classes
    // These follow the POSIX standard for character class names

    /// POSIX [:alnum:] - Alphanumeric characters [a-zA-Z0-9]
    pub const posix_alnum = createStaticCharClass(&[_]CharRange{
        CharRange.init('a', 'z'),
        CharRange.init('A', 'Z'),
        CharRange.init('0', '9'),
    }, false);

    /// POSIX [:alpha:] - Alphabetic characters [a-zA-Z]
    pub const posix_alpha = createStaticCharClass(&[_]CharRange{
        CharRange.init('a', 'z'),
        CharRange.init('A', 'Z'),
    }, false);

    /// POSIX [:blank:] - Space and tab [ \t]
    pub const posix_blank = createStaticCharClass(&[_]CharRange{
        CharRange.init(' ', ' '),
        CharRange.init('\t', '\t'),
    }, false);

    /// POSIX [:cntrl:] - Control characters [\x00-\x1F\x7F]
    pub const posix_cntrl = createStaticCharClass(&[_]CharRange{
        CharRange.init(0x00, 0x1F),
        CharRange.init(0x7F, 0x7F),
    }, false);

    /// POSIX [:digit:] - Digits [0-9]
    pub const posix_digit = createStaticCharClass(&[_]CharRange{
        CharRange.init('0', '9'),
    }, false);

    /// POSIX [:graph:] - Visible characters [\x21-\x7E]
    pub const posix_graph = createStaticCharClass(&[_]CharRange{
        CharRange.init(0x21, 0x7E),
    }, false);

    /// POSIX [:lower:] - Lowercase letters [a-z]
    pub const posix_lower = createStaticCharClass(&[_]CharRange{
        CharRange.init('a', 'z'),
    }, false);

    /// POSIX [:print:] - Printable characters [\x20-\x7E]
    pub const posix_print = createStaticCharClass(&[_]CharRange{
        CharRange.init(0x20, 0x7E),
    }, false);

    /// POSIX [:punct:] - Punctuation characters [!-/:-@\[-`{-~]
    pub const posix_punct = createStaticCharClass(&[_]CharRange{
        CharRange.init('!', '/'),
        CharRange.init(':', '@'),
        CharRange.init('[', '`'),
        CharRange.init('{', '~'),
    }, false);

    /// POSIX [:space:] - Whitespace characters [ \t\n\r\f\v]
    pub const posix_space = createStaticCharClass(&[_]CharRange{
        CharRange.init(' ', ' '),
        CharRange.init('\t', '\t'),
        CharRange.init('\n', '\n'),
        CharRange.init('\r', '\r'),
        CharRange.init(0x0C, 0x0C), // \f
        CharRange.init(0x0B, 0x0B), // \v
    }, false);

    /// POSIX [:upper:] - Uppercase letters [A-Z]
    pub const posix_upper = createStaticCharClass(&[_]CharRange{
        CharRange.init('A', 'Z'),
    }, false);

    /// POSIX [:xdigit:] - Hexadecimal digits [0-9A-Fa-f]
    pub const posix_xdigit = createStaticCharClass(&[_]CharRange{
        CharRange.init('0', '9'),
        CharRange.init('A', 'F'),
        CharRange.init('a', 'f'),
    }, false);
};

test "char range contains" {
    const range = CharRange.init('a', 'z');
    try std.testing.expect(range.contains('a'));
    try std.testing.expect(range.contains('m'));
    try std.testing.expect(range.contains('z'));
    try std.testing.expect(!range.contains('A'));
    try std.testing.expect(!range.contains('0'));
}

test "char class matches" {
    const digit_class = CharClasses.digit;
    try std.testing.expect(digit_class.matches('0'));
    try std.testing.expect(digit_class.matches('5'));
    try std.testing.expect(digit_class.matches('9'));
    try std.testing.expect(!digit_class.matches('a'));

    const non_digit_class = CharClasses.non_digit;
    try std.testing.expect(!non_digit_class.matches('0'));
    try std.testing.expect(non_digit_class.matches('a'));
}

test "word char class" {
    const word_class = CharClasses.word;
    try std.testing.expect(word_class.matches('a'));
    try std.testing.expect(word_class.matches('Z'));
    try std.testing.expect(word_class.matches('5'));
    try std.testing.expect(word_class.matches('_'));
    try std.testing.expect(!word_class.matches(' '));
    try std.testing.expect(!word_class.matches('-'));
}

test "whitespace char class" {
    const ws_class = CharClasses.whitespace;
    try std.testing.expect(ws_class.matches(' '));
    try std.testing.expect(ws_class.matches('\t'));
    try std.testing.expect(ws_class.matches('\n'));
    try std.testing.expect(!ws_class.matches('a'));
}
