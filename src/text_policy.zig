const std = @import("std");
const common = @import("common.zig");
const unicode = @import("unicode.zig");
const unicode_tables = @import("unicode_tables.zig");

pub const WordBoundaryPolicy = enum {
    ascii_default,
    unicode_ucp,
};

pub fn fromFlags(flags: common.CompileFlags) WordBoundaryPolicy {
    return if (flags.unicode) .unicode_ucp else .ascii_default;
}

pub fn validateUtf8(input: []const u8) !void {
    var pos: usize = 0;
    while (pos < input.len) {
        const decoded = try unicode.decodeUtf8(input[pos..]);
        pos += decoded.len;
    }
}

pub fn isLineBreakAt(input: []const u8, pos: usize) bool {
    if (pos >= input.len) return false;
    if (input[pos] == '\n' or input[pos] == '\r') return true;
    const decoded = unicode.decodeUtf8(input[pos..]) catch return false;
    return decoded.codepoint == 0x85 or decoded.codepoint == 0x2028 or decoded.codepoint == 0x2029;
}

pub fn isLineBreakBefore(input: []const u8, pos: usize) bool {
    if (pos == 0 or pos > input.len) return false;
    const prev_idx = unicode.stepBackward(input, pos);
    if (prev_idx >= input.len) return false;
    if (input[prev_idx] == '\n' or input[prev_idx] == '\r') return true;
    const decoded = unicode.decodeUtf8(input[prev_idx..]) catch return false;
    return decoded.codepoint == 0x85 or decoded.codepoint == 0x2028 or decoded.codepoint == 0x2029;
}

pub fn isWordBoundary(input: []const u8, pos: usize, policy: WordBoundaryPolicy) bool {
    const before_is_word = if (decodeUtf8Backward(input, pos)) |cp| isWordChar(cp, policy) else false;
    const after_is_word = if (decodeUtf8Forward(input, pos)) |cp| isWordChar(cp, policy) else false;
    return before_is_word != after_is_word;
}

pub fn isNonWordBoundary(input: []const u8, pos: usize, policy: WordBoundaryPolicy) bool {
    return !isWordBoundary(input, pos, policy);
}

pub fn isAbsoluteEnd(input: []const u8, pos: usize) bool {
    return pos == input.len;
}

pub fn isEndBeforeFinalNewline(input: []const u8, pos: usize) bool {
    if (pos == input.len) return true;
    if (pos > input.len) return false;

    if (pos + 1 == input.len and input[pos] == '\n') return true;
    if (pos + 1 == input.len and input[pos] == '\r') return true;
    if (pos + 2 == input.len and input[pos] == '\r' and input[pos + 1] == '\n') return true;

    return false;
}

fn isWordChar(cp: u21, policy: WordBoundaryPolicy) bool {
    return unicode_tables.isWordChar(cp, policy == .unicode_ucp);
}

fn decodeUtf8Forward(input: []const u8, pos: usize) ?u21 {
    if (pos >= input.len) return null;
    const decoded = unicode.decodeUtf8(input[pos..]) catch return null;
    return decoded.codepoint;
}

fn decodeUtf8Backward(input: []const u8, pos: usize) ?u21 {
    if (pos == 0) return null;
    const prev_idx = unicode.stepBackward(input, pos);
    const decoded = unicode.decodeUtf8(input[prev_idx..]) catch return null;
    return decoded.codepoint;
}

test "text_policy: default ascii boundary treats Ö as non-word" {
    try std.testing.expect(!isWordBoundary("Öyster", 0, .ascii_default));
}

test "text_policy: unicode boundary treats Ö as word" {
    try std.testing.expect(isWordBoundary("Öyster", 0, .unicode_ucp));
}
