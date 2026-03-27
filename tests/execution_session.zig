const std = @import("std");
const regex = @import("regex");

const Regex = regex.Regex;
const ExecutionSession = regex.ExecutionSession;
const SessionIterator = regex.SessionIterator;
const MatchBuffer = regex.MatchBuffer;
const RegexError = regex.RegexError;

fn expectMatch(session: *ExecutionSession, input: []const u8, expected: []const u8) !void {
    if (try session.find(input)) |match| {
        defer match.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(expected, match.slice);
    } else {
        return error.TestExpectedMatch;
    }
}

test "execution_session: reuses thompson session across inputs" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "hello");
    defer re.deinit();

    var session = try re.session(allocator);
    defer session.deinit();

    try expectMatch(&session, "xxhello", "hello");
    try std.testing.expect((try session.find("nomatch")) == null);
    try expectMatch(&session, "hello again", "hello");
}

test "execution_session: reuses backtracking session across inputs" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(.)\\1");
    defer re.deinit();

    var session = try re.session(allocator);
    defer session.deinit();

    try expectMatch(&session, "xaab", "aa");
    try std.testing.expect((try session.find("abcde")) == null);
    try expectMatch(&session, "zz", "zz");
}

test "execution_session: validates utf8 on every call" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "a+");
    defer re.deinit();

    var session = try re.session(allocator);
    defer session.deinit();

    try std.testing.expectError(RegexError.InvalidUtf8, session.find("\xFF"));
    try std.testing.expect(try session.isMatch("aaa"));
}

test "execution_session: iterator behavior remains stable with session infra" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\w+");
    defer re.deinit();

    var iter = re.iterator("one two three");
    defer iter.deinit();

    if (try iter.next(allocator)) |m1| {
        defer m1.deinit(allocator);
        try std.testing.expectEqualStrings("one", m1.slice);
    } else return error.TestExpectedMatch;

    if (try iter.next(allocator)) |m2| {
        defer m2.deinit(allocator);
        try std.testing.expectEqualStrings("two", m2.slice);
    } else return error.TestExpectedMatch;

    if (try iter.next(allocator)) |m3| {
        defer m3.deinit(allocator);
        try std.testing.expectEqualStrings("three", m3.slice);
    } else return error.TestExpectedMatch;

    try std.testing.expect((try iter.next(allocator)) == null);
}

test "execution_session: explicit max steps control is safe for both engine families" {
    const allocator = std.testing.allocator;

    var nfa_re = try Regex.compile(allocator, "abc");
    defer nfa_re.deinit();
    var nfa_session = try nfa_re.session(allocator);
    defer nfa_session.deinit();
    nfa_session.setMaxSteps(1);
    try expectMatch(&nfa_session, "abc", "abc");

    var backtrack_re = try Regex.compile(allocator, "(.)\\1");
    defer backtrack_re.deinit();
    var backtrack_session = try backtrack_re.session(allocator);
    defer backtrack_session.deinit();
    backtrack_session.setMaxSteps(1_000);
    try expectMatch(&backtrack_session, "aabb", "aa");
}

test "execution_session: findInto reuses a thompson buffer" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(he)(llo)");
    defer re.deinit();

    var session = try re.session(allocator);
    defer session.deinit();

    var buffer = try re.matchBuffer(allocator);
    defer buffer.deinit();

    try std.testing.expect(try session.findInto("xxhello", &buffer));
    try std.testing.expect(buffer.matched);
    try std.testing.expectEqualStrings("hello", buffer.slice);
    try std.testing.expectEqualStrings("he", buffer.captures[0].text);
    try std.testing.expectEqualStrings("llo", buffer.captures[1].text);

    try std.testing.expect(!(try session.findInto("nomatch", &buffer)));
    try std.testing.expect(!buffer.matched);
    try std.testing.expectEqualStrings("", buffer.slice);

    try std.testing.expect(try session.findInto("hello again", &buffer));
    try std.testing.expectEqualStrings("hello", buffer.slice);
}

test "execution_session: findInto reuses a backtracking buffer" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(.)\\1");
    defer re.deinit();

    var session = try re.session(allocator);
    defer session.deinit();

    var buffer = try re.matchBuffer(allocator);
    defer buffer.deinit();

    try std.testing.expect(try session.findInto("xaab", &buffer));
    try std.testing.expect(buffer.matched);
    try std.testing.expectEqualStrings("aa", buffer.slice);
    try std.testing.expectEqualStrings("a", buffer.captures[0].text);

    try std.testing.expect(try re.findInto("zz", &buffer));
    try std.testing.expectEqualStrings("zz", buffer.slice);
    try std.testing.expectEqualStrings("z", buffer.captures[0].text);
}

test "execution_session: findInto rejects wrong-sized buffer" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(a)(b)");
    defer re.deinit();

    var session = try re.session(allocator);
    defer session.deinit();

    var buffer = try MatchBuffer.init(allocator, 1);
    defer buffer.deinit();

    try std.testing.expectError(RegexError.InvalidArgument, session.findInto("ab", &buffer));
}

test "execution_session: findAll reuses bulk primitive for multiple thompson matches" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(ab)");
    defer re.deinit();

    const matches = try re.findAll(allocator, "ab xx ab yy ab");
    defer {
        for (matches) |match| match.deinit(allocator);
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("ab", matches[0].slice);
    try std.testing.expectEqualStrings("ab", matches[1].slice);
    try std.testing.expectEqualStrings("ab", matches[2].slice);
    try std.testing.expectEqualStrings("ab", matches[0].captures[0]);
}

test "execution_session: findAll handles zero-width matches without looping forever" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\b");
    defer re.deinit();

    const matches = try re.findAll(allocator, "ab cd");
    defer {
        for (matches) |match| match.deinit(allocator);
        allocator.free(matches);
    }

    try std.testing.expect(matches.len >= 2);
    for (matches) |match| {
        try std.testing.expectEqualStrings("", match.slice);
    }
}

test "execution_session: findAll preserves backtracking semantics" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(.)\\1");
    defer re.deinit();

    const matches = try re.findAll(allocator, "aabbcc");
    defer {
        for (matches) |match| match.deinit(allocator);
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("aa", matches[0].slice);
    try std.testing.expectEqualStrings("bb", matches[1].slice);
    try std.testing.expectEqualStrings("cc", matches[2].slice);
}

test "execution_session: replaceAll streams over reusable primitive" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(ab)");
    defer re.deinit();

    const result = try re.replaceAll(allocator, "ab xx ab yy ab", "<$1>");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("<ab> xx <ab> yy <ab>", result);
}

test "execution_session: split streams over reusable primitive" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "\\s+");
    defer re.deinit();

    const parts = try re.split(allocator, "one   two\tthree");
    defer allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("one", parts[0]);
    try std.testing.expectEqualStrings("two", parts[1]);
    try std.testing.expectEqualStrings("three", parts[2]);
}

test "execution_session: session iterator reuses session and caller buffer" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(.)\\1");
    defer re.deinit();

    var session = try re.session(allocator);
    defer session.deinit();

    var iter: SessionIterator = session.iterator("aabbcc");
    var buffer = try re.matchBuffer(allocator);
    defer buffer.deinit();

    try std.testing.expect(try iter.nextInto(&buffer));
    try std.testing.expectEqualStrings("aa", buffer.slice);
    try std.testing.expectEqualStrings("a", buffer.captures[0].text);

    try std.testing.expect(try iter.nextInto(&buffer));
    try std.testing.expectEqualStrings("bb", buffer.slice);
    try std.testing.expectEqualStrings("b", buffer.captures[0].text);

    try std.testing.expect(try iter.nextInto(&buffer));
    try std.testing.expectEqualStrings("cc", buffer.slice);
    try std.testing.expectEqualStrings("c", buffer.captures[0].text);

    try std.testing.expect(!(try iter.nextInto(&buffer)));
    try std.testing.expect(!buffer.matched);
}

test "execution_session: matcher compatibility alias still works" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "hello");
    defer re.deinit();

    var matcher = try re.matcher(allocator);
    defer matcher.deinit();

    if (try matcher.find("xxhello")) |match| {
        defer match.deinit(allocator);
        try std.testing.expectEqualStrings("hello", match.slice);
    } else return error.TestExpectedMatch;
}
