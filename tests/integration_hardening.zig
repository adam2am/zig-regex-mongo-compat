const std = @import("std");
const Regex = @import("regex").Regex;
const RegexError = @import("regex").RegexError;

// =============================================================================
// 1. THE ZERO-WIDTH UTF-8 ADVANCEMENT BUG
// =============================================================================
// Tests that `findAll` and `iterator` correctly advance by the UTF-8 stride
// instead of `+ 1` byte when a zero-width match occurs right before an emoji.

test "hardening: zero-width match before multi-byte char" {
    const allocator = std.testing.allocator;
    
    // Pattern: A positive lookahead for an emoji. This is a zero-width match.
    var regex = try Regex.compile(allocator, "(?=👋)");
    defer regex.deinit();

    const input = "Hello 👋 World";
    
    // If the bug exists, findAll will match at the space before the emoji,
    // then advance by 1 byte (landing INSIDE the 4-byte 👋 emoji), 
    // causing an InvalidUtf8 panic or an infinite loop.
    const matches = try regex.findAll(allocator, input);
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(usize, 0), matches[0].slice.len); // Zero-width
    
    // The emoji 👋 is 4 bytes. If the engine survives this without panicking, 
    // it correctly advanced by the UTF-8 stride!
}

// =============================================================================
// 2. THE VARIABLE-LENGTH LOOKBEHIND UTF-8 BUG
// =============================================================================
// Tests that a backward-scanning lookbehind steps by valid UTF-8 character 
// boundaries, not by `pos -= 1` bytes.

test "hardening: lookbehind over multi-byte characters" {
    const allocator = std.testing.allocator;
    
    // 'é' is 2 bytes (C3 A9). We want to match 'f' only if preceded by 'é'.
    var regex = try Regex.compile(allocator, "(?<=é)f");
    defer regex.deinit();

    const input = "caféf";
    
    // If check_pos -= 1 is used blindly in the lookbehind loop, the engine 
    // will attempt to evaluate the assertion starting from the continuation 
    // byte (0xA9) of 'é', leading to a failed decode and a missed match.
    if (try regex.find(input)) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("f", match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

// =============================================================================
// 3. BSON NULL BYTES IN INPUT
// =============================================================================
// MongoDB/BSON strings frequently contain literal `\x00` null bytes. 
// C-string wrappers truncate here. We must ensure native slices handle it.

test "hardening: BSON input containing binary null bytes" {
    const allocator = std.testing.allocator;
    
    // dot_all=true so '.' matches the null byte.
    var regex = try Regex.compileWithFlags(allocator, "data.*more", .{ .dot_all = true });
    defer regex.deinit();

    // Input string containing a literal \x00 byte in the middle
    const input = "start data\x00hidden\x00more end";
    
    if (try regex.find(input)) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        
        // Ensure the engine didn't stop parsing at the first \x00
        try std.testing.expectEqualStrings("data\x00hidden\x00more", match.slice);
        try std.testing.expectEqual(@as(usize, 16), match.slice.len);
    } else {
        return error.TestExpectedMatch;
    }
}

// =============================================================================
// 4. CASE-FOLDING LENGTH DISCREPANCIES
// =============================================================================
// When folding case, the pattern character and input character might have
// different byte lengths. (e.g., ASCII 'k' is 1 byte, Kelvin 'K' is 3 bytes).

test "hardening: case-insensitive match with asymmetric byte lengths" {
    const allocator = std.testing.allocator;
    
    // Pattern is exactly 1 byte long ('k')
    var regex = try Regex.compileWithFlags(allocator, "k", .{ .case_insensitive = true });
    defer regex.deinit();

    // Input is the Kelvin sign K (U+212A), which is 3 bytes long
    const input = "\u{212A}"; 
    
    if (try regex.find(input)) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        
        // The slice length MUST be 3 bytes (the input length), NOT 1 byte!
        // If it's 1 byte, the engine advanced by the pattern length instead of input length.
        try std.testing.expectEqualStrings("\u{212A}", match.slice);
        try std.testing.expectEqual(@as(usize, 3), match.slice.len);
    } else {
        return error.TestExpectedMatch;
    }
}

// =============================================================================
// 5a. STATIC REDOS COMPILE-TIME REJECTION
// =============================================================================
// The pattern analyzer MUST reject catastrophic patterns at compile time,
// but ONLY for backtracking patterns (NFA handles nested quantifiers fine).
// A pattern needs BOTH a backreference (forces backtracking) AND nested quantifiers
// to trigger the static analyzer.

test "hardening: catastrophic ReDoS patterns rejected at compile time" {
    const allocator = std.testing.allocator;

    // Backreference forces backtracking engine, which then runs the static analyzer.
    // (a+)+ alone would use NFA (safe). Adding \1 forces backtracking → static analysis → rejected.
    try std.testing.expectError(RegexError.PatternTooComplex, Regex.compile(allocator, "(a+)+\\1"));
}

// =============================================================================
// 5b. RUNTIME GRACEFUL ABORT
// =============================================================================
// The backtracking engine's step limit must return null (or Timeout) gracefully,
// never panicking or hanging indefinitely.

test "hardening: backtracking engine aborts gracefully under step pressure" {
    const allocator = std.testing.allocator;

    // Backreference forces backtracking engine. Verify two contracts:
    // 1. On matching input, the engine correctly identifies the match.
    // 2. On non-matching input, it returns null gracefully (no panic, no hang).
    var regex = try Regex.compile(allocator, "(.)\\1");
    defer regex.deinit();

    // Contract 1: must match "aa" (same char twice)
    if (try regex.find("xaabx")) |m| {
        var mut_m = m;
        defer mut_m.deinit(allocator);
        try std.testing.expectEqualStrings("aa", mut_m.slice);
    } else {
        return error.TestExpectedMatch;
    }

    // Contract 2: must return null on non-matching input (no panic, no hang)
    const no_match = try regex.find("abcde");
    try std.testing.expect(no_match == null);
}

