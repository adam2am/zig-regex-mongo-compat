const std = @import("std");
const Regex = @import("regex").Regex;
const RegexError = @import("regex").RegexError;
const CompileFlags = @import("regex").common.CompileFlags;

// =============================================================================
// Parser and compiler edge cases - invalid patterns, boundary syntax, etc.
// =============================================================================

// --- Invalid pattern rejection ---

test "parser: quantifier ? at start is rejected" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "?abc");
    try std.testing.expectError(RegexError.UnexpectedCharacter, result);
}

test "parser: nested empty groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(())");
    defer regex.deinit();
    // Should compile without error
    try std.testing.expect(try regex.isMatch(""));
}

test "parser: deeply nested groups" {
    const allocator = std.testing.allocator;
    // 20 levels of nesting - should be within limits
    var regex = try Regex.compile(allocator, "((((((((((((((((((((a))))))))))))))))))))");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("a"));
}

test "parser: consecutive quantifiers are rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(RegexError.InvalidQuantifier, Regex.compile(allocator, "a**"));
}

test "parser: quantifier on quantifier is rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(RegexError.InvalidQuantifier, Regex.compile(allocator, "a+*"));
}

test "parser: empty alternation branch is valid" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a|");
    defer regex.deinit();
    // "a|" means "a or empty string" - should match empty
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch(""));
}

test "parser: leading pipe alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "|a");
    defer regex.deinit();
    // "|a" means "empty string or a"
    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
}

// --- Quantifier syntax edge cases ---

test "parser: {0} means zero occurrences" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^a{0}b$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("b"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

test "parser: {1} means exactly once" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^a{1}$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("aa"));
    try std.testing.expect(!try regex.isMatch(""));
}

test "parser: large but valid quantifier" {
    const allocator = std.testing.allocator;
    // {0,100} should be valid
    var regex = try Regex.compile(allocator, "a{0,100}");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch(""));
}

test "atomic group: basic syntax (?>...)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?>abc)");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

test "atomic group: prevents backtracking" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?>a+)ab");
    defer regex.deinit();

    // Atomic group consumes all 'a's, no backtracking to match 'ab'
    try std.testing.expect(!try regex.isMatch("aaab"));
}

test "atomic group: nested with alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?>a|ab)c");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("ac"));
    // 'ab' is consumed atomically, can't backtrack to match 'a' then 'bc'
    try std.testing.expect(!try regex.isMatch("abc"));
}

test "atomic group: with quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?>\\d+)\\d");
    defer regex.deinit();

    // Atomic group consumes all digits, no backtracking
    try std.testing.expect(!try regex.isMatch("123"));
}

// --- Character class syntax edge cases ---

test "parser: character class with escaped ]" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[\\]]");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("]"));
    try std.testing.expect(!try regex.isMatch("a"));
}

test "parser: character class with hyphen between ranges" {
    const allocator = std.testing.allocator;
    // Hyphen at start is literal, not range
    var regex = try Regex.compile(allocator, "[-az]");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("-"));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("z"));
    try std.testing.expect(!try regex.isMatch("m"));
}

test "parser: negated class with range" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^[^0-9]+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("abc123"));
    try std.testing.expect(!try regex.isMatch("1"));
}

// --- Escape sequence edge cases ---

test "parser: tab and newline escapes" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\t");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("\t"));
    try std.testing.expect(!try regex.isMatch("t"));
}

test "parser: carriage return escape" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\r\\n");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("\r\n"));
}

test "parser: escaped caret and dollar" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\^\\$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("^$"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

// --- Complex pattern compilation ---

test "compiler: alternation with quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(ab+|cd*)e$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abe"));
    try std.testing.expect(try regex.isMatch("abbbe"));
    try std.testing.expect(try regex.isMatch("ce"));
    try std.testing.expect(try regex.isMatch("cdddde"));
    try std.testing.expect(!try regex.isMatch("ae"));
    try std.testing.expect(!try regex.isMatch("de"));
}

test "compiler: character class in alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^([0-9]+|[a-z]+)$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("123"));
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("abc123"));
    try std.testing.expect(!try regex.isMatch("ABC"));
}

test "compiler: optional group" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^colou?r$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("color"));
    try std.testing.expect(try regex.isMatch("colour"));
    try std.testing.expect(!try regex.isMatch("colouur"));
}

test "compiler: optional group with parentheses" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^(un)?happy$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("happy"));
    try std.testing.expect(try regex.isMatch("unhappy"));
    try std.testing.expect(!try regex.isMatch("unununhappy"));
}

test "compiler: multiple capture groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d{4})-(\\d{2})-(\\d{2})");
    defer regex.deinit();

    if (try regex.find("Today is 2024-01-15!")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqualStrings("2024-01-15", match.slice);
        try std.testing.expect(match.captures.len >= 3);
        try std.testing.expectEqualStrings("2024", match.captures[0]);
        try std.testing.expectEqualStrings("01", match.captures[1]);
        try std.testing.expectEqualStrings("15", match.captures[2]);
    } else {
        return error.TestExpectedMatch;
    }
}

// --- Anchored optimization edge cases ---

test "compiler: anchored pattern only tries position 0" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^abc");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abcdef"));
    try std.testing.expect(!try regex.isMatch("xabc"));
    try std.testing.expect(!try regex.isMatch(""));
}

test "compiler: end-anchored pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "abc$");
    defer regex.deinit();

    if (try regex.find("xyzabc")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 3), match.start);
    } else {
        return error.TestExpectedMatch;
    }
}

test "compiler: both anchors" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^exact$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("exact"));
    try std.testing.expect(!try regex.isMatch("not exact"));
    try std.testing.expect(!try regex.isMatch("exact not"));
    try std.testing.expect(!try regex.isMatch(""));
}

// --- Complex real-world patterns ---

test "compiler: password strength check" {
    const allocator = std.testing.allocator;
    var has_digit = try Regex.compile(allocator, "\\d");
    defer has_digit.deinit();
    var has_lower = try Regex.compile(allocator, "[a-z]");
    defer has_lower.deinit();
    var has_upper = try Regex.compile(allocator, "[A-Z]");
    defer has_upper.deinit();
    var min_length = try Regex.compile(allocator, ".{8,}");
    defer min_length.deinit();

    const password = "MyP4ssword";
    try std.testing.expect(try has_digit.isMatch(password));
    try std.testing.expect(try has_lower.isMatch(password));
    try std.testing.expect(try has_upper.isMatch(password));
    try std.testing.expect(try min_length.isMatch(password));

    const weak = "weak";
    try std.testing.expect(!try has_digit.isMatch(weak));
    try std.testing.expect(!try has_upper.isMatch(weak));
    try std.testing.expect(!try min_length.isMatch(weak));
}

test "compiler: CSV field extraction" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[^,]+");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, "foo,bar,baz");
    defer {
        for (matches) |*m| {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("foo", matches[0].slice);
    try std.testing.expectEqualStrings("bar", matches[1].slice);
    try std.testing.expectEqualStrings("baz", matches[2].slice);
}

test "compiler: whitespace normalization via replaceAll" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\s+");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "  hello   world  ", " ");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" hello world ", result);
}

// --- Edge: pattern with only anchors ---

test "compiler: pattern with only ^ anchor" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^");
    defer regex.deinit();

    // ^ matches at position 0 of any string (matches zero-width)
    try std.testing.expect(try regex.isMatch("anything"));
    try std.testing.expect(try regex.isMatch(""));
}

test "compiler: pattern with only $ anchor" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "$");
    defer regex.deinit();

    // $ matches at end of any string (zero-width)
    try std.testing.expect(try regex.isMatch("anything"));
    try std.testing.expect(try regex.isMatch(""));
}

// --- Dot with quantifiers ---

test "compiler: dot plus" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^.+$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch(""));
}

test "compiler: dot question" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^.?$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(""));
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

test "compiler: dot repeat" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^.{3}$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(try regex.isMatch("123"));
    try std.testing.expect(!try regex.isMatch("ab"));
    try std.testing.expect(!try regex.isMatch("abcd"));
}

// --- PCRE-specific structural edge cases ---

test "parser: PCRE comments (?#...) are stripped by lexer" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "a(?# this is a comment )b");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("ab"));
    try std.testing.expect(!try regex.isMatch("a(?# this is a comment )b"));
}

test "parser: quantifier on anchor ^* is rejected" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "^*a");
    try std.testing.expectError(RegexError.InvalidQuantifier, result);
}

test "parser: quantifier on lookahead (?=foo)+ is rejected" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "(?=foo)+");
    try std.testing.expectError(RegexError.InvalidQuantifier, result);
}

test "parser: empty character class [] first ] is treated as literal" {
    const allocator = std.testing.allocator;
    // []] = character class containing only ']'
    var regex = try Regex.compile(allocator, "[]]");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("]"));
    try std.testing.expect(!try regex.isMatch("a"));
}

test "parser: unclosed POSIX class [[:alpha] is rejected" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "[[:alpha]");
    try std.testing.expectError(RegexError.InvalidCharacterClass, result);
}

test "parser: escaped anchor literals \\^ and \\$" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\^abc\\$");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("^abc$"));
    try std.testing.expect(!try regex.isMatch("abc"));
}

test "parser: escaped dot literal file\\.txt" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "file\\.txt");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("file.txt"));
    try std.testing.expect(!try regex.isMatch("fileXtxt"));
}

test "parser: trailing backslash is an error" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "abc\\");
    try std.testing.expectError(RegexError.UnexpectedEndOfPattern, result);
}

test "parser: incomplete hex sequence is an error" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "\\x1");
    try std.testing.expectError(RegexError.UnexpectedEndOfPattern, result);
}

test "parser: null byte in pattern is an error" {
    const allocator = std.testing.allocator;
    const result = Regex.compile(allocator, "A\\x00B");
    try std.testing.expectError(RegexError.InvalidPattern, result);
}

test "parser: \\Q...\\E quotes metacharacters literally" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\Q[a-z]+(foo)?\\E");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("[a-z]+(foo)?"));
    try std.testing.expect(!try regex.isMatch("abc"));
}

test "parser: \\Q...\\E re-enables regex syntax after \\E" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\Qabc.\\E\\d+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc.123"));
    try std.testing.expect(!try regex.isMatch("abc.xyz"));
}

test "parser: \\Q...\\E makes alternation literal" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\Qa|b\\E");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a|b"));
    try std.testing.expect(!try regex.isMatch("a"));
}

test "parser: \\Q...\\E quotes quantifiers and dot literally" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\Q.*+?\\E$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch(".*+?"));
    try std.testing.expect(!try regex.isMatch("...."));
}

test "parser: \\Q...\\E with trailing active regex syntax" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\Q(test)\\E(test)$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("(test)test"));
    try std.testing.expect(!try regex.isMatch("testtest"));
}

test "parser: \\Q...\\E with unicode literal payload" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\Qé+🙂\\E$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("é+🙂"));
    try std.testing.expect(!try regex.isMatch("é🙂"));
}

test "parser: unterminated \\Q quotes remainder literally" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\Qabc");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

test "parser: \\Q...\\E with Unicode BMP payload only" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\Qé+\\E$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("é+"));
    try std.testing.expect(!try regex.isMatch("é"));
}

test "parser: \\Q...\\E with emoji payload only" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\Q🙂\\E$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("🙂"));
    try std.testing.expect(!try regex.isMatch("x"));
}

test "parser: \\Q...\\E with mixed Unicode and ASCII payload" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^\\Qé+🙂\\E$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("é+🙂"));
    try std.testing.expect(!try regex.isMatch("é🙂"));
}

test "parser: quoted Unicode resumes active regex after \\E" {
    const allocator = std.testing.allocator;
    var regex_compiled = try Regex.compile(allocator, "\\Qé.\\E\\d+");
    defer regex_compiled.deinit();

    try std.testing.expect(try regex_compiled.isMatch("é.123"));
    try std.testing.expect(!try regex_compiled.isMatch("é.xyz"));
}

test "compileWithFlags: empty Unicode property is rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(RegexError.InvalidUnicodeProperty, Regex.compileWithFlags(allocator, "\\p{}", CompileFlags{}));
}

test "compileWithFlags: nonexistent numeric backreference is rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(RegexError.InvalidBackreference, Regex.compileWithFlags(allocator, "\\9", CompileFlags{}));
}

test "compileWithFlags: nonexistent named backreference is rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(RegexError.InvalidBackreference, Regex.compileWithFlags(allocator, "\\k<missing>", CompileFlags{}));
}

test "compileWithFlags: quoted Unicode literal compiles and matches" {
    const allocator = std.testing.allocator;
    var regex_compiled = try Regex.compileWithFlags(allocator, "^\\Qé+🙂\\E$", CompileFlags{});
    defer regex_compiled.deinit();

    try std.testing.expect(try regex_compiled.isMatch("é+🙂"));
    try std.testing.expect(!try regex_compiled.isMatch("é🙂"));
}

