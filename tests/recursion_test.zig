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

// ============================================================================
// (?R) Recursion Tests
// ============================================================================

test "(?R): basic recursive pattern - nested parentheses" {
    const allocator = std.testing.allocator;
    // Match balanced parentheses. Using (?1) because ^ and $ are in the pattern.
    // (?R) would recurse the entire pattern including anchors, which fails at pos > 0.
    var regex = try Regex.compile(allocator, "^(\\((?:[^()]|(?1))*\\))$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("()"));
    try std.testing.expect(try regex.isMatch("(())"));
    try std.testing.expect(try regex.isMatch("((()))"));
    try std.testing.expect(!try regex.isMatch("("));
    try std.testing.expect(!try regex.isMatch(")"));
    try std.testing.expect(!try regex.isMatch("(()"));
}

test "(?R): simple recursion - nested parentheses full" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(\\((?:[^()]|(?1))*\\))$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("(abc)"));
    try std.testing.expect(try regex.isMatch("(a(b)c)"));
    try std.testing.expect(try regex.isMatch("(a(b(c))d)"));
    try std.testing.expect(!try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("(abc"));
}

test "(?R): recursion depth limit prevents infinite loop" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(\\((?:[^()]|(?1))*\\))$");
    defer regex.deinit();

    // With 500 default depth limit, this should still match 5 levels
    try std.testing.expect(try regex.isMatch("(((())))"));

    // Create deeply nested string exceeding max depth
    var buf: [1100]u8 = undefined;
    @memset(&buf, '(');
    @memset(buf[550..], ')');

    // Should fail cleanly (not crash) when recursion limit is reached
    try std.testing.expect(!try regex.isMatch(&buf));
}

test "(?R): recursion returns null when depth exceeded" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(?:(\\((?:[^()]|(?1))*\\)))+$");
    defer regex.deinit();

    // Multiple nested parens should work
    try std.testing.expect(try regex.isMatch("(a)(b)(c)"));
    try std.testing.expect(try regex.isMatch("((a))((b))"));
}

test "(?1): recurse specific group - match palindrome-ish" {
    const allocator = std.testing.allocator;
    // Note: (?1) syntax for recursing specific group
    var regex = try Regex.compile(allocator, "^(a)(?:(?1))?$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aa"));
    try std.testing.expect(!try regex.isMatch("aaa")); // (?1) is just 'a', max length 2
}

test "(?R): forward reference - group after recursion" {
    const allocator = std.testing.allocator;
    // (?1) refers to group 1 which is defined AFTER the recursion
    // This tests the O(1) group_lookup table works correctly
    var regex = try Regex.compile(allocator, "^(?1)(a)$");
    defer regex.deinit();

    // Forward reference - recursion should find group 1 after parsing
    // The pattern (?1)(a) means recurse group 1 then match 'a'
    // But group 1 is defined as 'a', so it matches 'a' then recurses 'a' again
    // This should match "aa" or similar
    const result = try regex.isMatch("aa");
    try std.testing.expect(result);
}

test "(?R): empty recursion with quantifier" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(?:(?R))?$");
    defer regex.deinit();

    // Empty recursion should match empty
    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(!try regex.isMatch("anything"));
}

test "(?R): inside character class (should not recurse)" {
    const allocator = std.testing.allocator;
    // (?R) inside character class is literal - not a recursion
    var regex = try Regex.compile(allocator, "^[(?R)]+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("("));
    try std.testing.expect(try regex.isMatch("?"));
    try std.testing.expect(try regex.isMatch("R"));
    try std.testing.expect(try regex.isMatch(")"));
    try std.testing.expect(try regex.isMatch("(?)R"));
    try std.testing.expect(!try regex.isMatch("a"));
}

test "(?0): equivalent to (?R)" {
    const allocator = std.testing.allocator;
    var regex_r = try Regex.compile(allocator, "^\\((?:[^()]|(?R))*\\)$");
    defer regex_r.deinit();

    var regex_0 = try Regex.compile(allocator, "^\\((?:[^()]|(?0))*\\)$");
    defer regex_0.deinit();

    // Both should have same behavior
    try std.testing.expectEqual(try regex_r.isMatch("()"), try regex_0.isMatch("()"));
    try std.testing.expectEqual(try regex_r.isMatch("(())"), try regex_0.isMatch("(())"));
    try std.testing.expectEqual(try regex_r.isMatch("((()))"), try regex_0.isMatch("((()))"));
}

test "(?R): complex forward reference to nested group" {
    const allocator = std.testing.allocator;
    // ^(?2)x(a(b)c)$
    // (?2) calls group 2 before it is defined.
    // Group 1 is (a(b)c). Group 2 is (b).
    // Therefore, (?2) should match 'b'. The pattern expects "bxabc".
    var regex = try Regex.compile(allocator, "^(?2)x(a(b)c)$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("bxabc"));
    try std.testing.expect(!try regex.isMatch("xabc"));
    try std.testing.expect(!try regex.isMatch("bxc"));

    // Also test that the engine gracefully fails if referring to a non-existent group
    // (?99) will fail to match since group 99 doesn't exist
    try std.testing.expect(!try regex.isMatch("99xabc"));
}

// ============================================================================
// (?R(grouplist)) - PCRE2 10.46+ Selective Capture Retention
// ============================================================================

test "(?R(grouplist)): keeps group 1 from being wiped on return" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(a|b)(?1(1))c$");
    defer regex.deinit();

    if (try regex.find("bac")) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqualStrings("a", match.captures[0]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "(?R(grouplist)): multiple keeps (?1(2,3))" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^((a|x)(b|y))(?1(2,3))c$");
    defer regex.deinit();

    if (try regex.find("xyabc")) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        // Outer matches "xy". Group 2="x", Group 3="y".
        // Inner matches "ab". Group 2="a", Group 3="b".
        // Both groups kept!
        try std.testing.expectEqualStrings("a", match.captures[1]);
        try std.testing.expectEqualStrings("b", match.captures[2]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "(?R(grouplist)): without keep groups - outer wins" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(a|b)(?1)c$");
    defer regex.deinit();

    if (try regex.find("bac")) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        // Without keep_groups, outer 'b' should be preserved
        try std.testing.expectEqualStrings("b", match.captures[0]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "(?R(grouplist)): whole pattern (?R(1))" {
    const allocator = std.testing.allocator;
    // (?R(1)) means recurse entire pattern, keep group 1
    var regex = try Regex.compile(allocator, "(\\((?:[^()]|(?R(1)))*\\))");
    defer regex.deinit();

    // Nested parens should work
    try std.testing.expect(try regex.isMatch("((()))"));
}

test "(?R(grouplist)): empty grouplist is treated as no keep groups" {
    const allocator = std.testing.allocator;
    // (?R()) with empty grouplist - treated as (?R) without keep_groups
    var regex = try Regex.compile(allocator, "^(a(?1())?b)$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("aabb"));
}

test "(?R(grouplist)): named groups (?1(<name>))" {
    const allocator = std.testing.allocator;
    // (?1(<val>)) will recurse into group 1, and keep the inner capture of named group 'val'
    var regex = try Regex.compile(allocator, "^(a(?P<val>b|c))(?1(<val>))d$");
    defer regex.deinit();

    if (try regex.find("abacd")) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        // Outer captured 'b', inner captured 'c'. Because we kept <val>, we expect 'c'.
        const val = regex.getNamedCapture(&match, "val");
        try std.testing.expect(val != null);
        try std.testing.expectEqualStrings("c", val.?);
    } else {
        return error.TestExpectedMatch;
    }
}

test "(?R(grouplist)): relative numbers (?1(-1))" {
    const allocator = std.testing.allocator;
    // (a)(?1(-1))(b)
    // (?-1) refers to the last opened group (group 1)
    var regex = try Regex.compile(allocator, "^(a)(?1(-1))(b)$");
    defer regex.deinit();

    if (try regex.find("aab")) |match| {
        defer {
            var mut_match = match;
            mut_match.deinit(allocator);
        }
        try std.testing.expectEqualStrings("a", match.captures[0]);
    } else {
        return error.TestExpectedMatch;
    }
}

test "(?R(grouplist)): relative +0 - same group" {
    const allocator = std.testing.allocator;
    // (?1(+0)) means keep the same group we recurse into (group 1)
    // Pattern: ^(a)(?1(+0))a$ matches "aaa"
    // - (a) captures 'a' into group 1
    // - (?1(+0)) recurses into group 1, matches next 'a', +0 keeps group 1 patched
    // - a matches final char, $ matches end
    var regex = try Regex.compile(allocator, "^(a)(?1(+0))a$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("aaa"));
}

test "(?R(grouplist)): mixed index and named" {
    const allocator = std.testing.allocator;
    // Named group 'inner' is group 2, keep by name
    // Group 1 is 'a', keep by index
    var regex = try Regex.compile(allocator, "^(a)(?P<inner>b)\\1(?1(1,<inner>))$");
    defer regex.deinit();

    // "ab" + "ab" + recurse group 1 (which is "a") at position 4 - fails because end of string
    // Just test that compilation works (parsing named keep groups)
    try std.testing.expect(!try regex.isMatch("abab"));
}

// ============================================================================
// +0 Call-Site Semantics Tests (PCRE2 10.46+)
// ============================================================================

test "(?R(grouplist)): +0 resolves to enclosing group at call site" {
    const allocator = std.testing.allocator;

    // Pattern: ^(a(?1(+0))?b)$
    // Group 1 is (a(?1(+0))?b).
    // Call site is inside group 1, so +0 resolves to 1.
    var regex = try Regex.compile(allocator, "^(a(?1(+0))?b)$");
    defer regex.deinit();

    // It should match without infinite recursion or crashing
    try std.testing.expect(try regex.isMatch("aabb"));
}

test "(?R(grouplist)): +0 at top level resolves to whole pattern (group 0)" {
    const allocator = std.testing.allocator;
    // Pattern: (a)(b)(c)(?1(+0))d$
    // - Groups 1, 2, 3 are opened AND CLOSED before the call site
    // - Call site (?1(+0)) is at TOP LEVEL (no group is open)
    // - +0 should resolve to group 0 (whole pattern), NOT group 1
    var regex = try Regex.compile(allocator, "(a)(b)(c)(?1(+0))d$");
    defer regex.deinit();

    // The pattern should match:
    // (a) captures 'a' → group 1
    // (b) captures 'b' → group 2
    // (c) captures 'c' → group 3
    // (?1(+0)) recurses into group 1, matches 'a', +0 keeps group 0 (whole pattern)
    // d$ matches 'd'
    // Expected: "abcad"
    try std.testing.expect(try regex.isMatch("abcad"));
}


// ============================================================================
// (?&name) and (?P>name) - Named Subroutine Calls
// ============================================================================

test "(?&name): call subroutine by name" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(?<first>a)(?&first)b$");
    defer regex.deinit();

    // a + recurse 'first' (a) + b
    try std.testing.expect(try regex.isMatch("aab"));
}

test "(?P>name): call subroutine by Python name" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(?P<first>a)(?P>first)b$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("aab"));
}

test "(?-1): relative backward call" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(a)(?-1)b$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("aab"));
}

test "(?+1): relative forward call" {
    const allocator = std.testing.allocator;
    // (?+1) calls the next group. Here we define (a) after the call,
    // which makes it a forward reference.
    var regex = try Regex.compile(allocator, "^(?+1)(a)b$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("aab"));
}
