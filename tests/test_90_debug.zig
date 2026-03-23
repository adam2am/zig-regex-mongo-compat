const std = @import("std");
const regex = @import("regex");

test "Debug Test 90: (*UCP)\\byster matching Öyster" {
    const allocator = std.testing.allocator;
    const Regex = regex.Regex;

    const pattern = "(*UCP)\\byster";
    const input = "Öyster";

    std.debug.print("\n=== Debugging Test 90 ===\n", .{});
    std.debug.print("Pattern: {s}\n", .{pattern});
    std.debug.print("Input: {s}\n", .{input});
    std.debug.print("Input bytes: ", .{});
    for (input) |b| std.debug.print("{x:0>2} ", .{b});
    std.debug.print("\n\n", .{});

    // Check each UTF-8 position
    std.debug.print("UTF-8 positions in input:\n", .{});
    var pos: usize = 0;
    var pos_num: usize = 0;
    while (pos < input.len) {
        const len = std.unicode.utf8ByteSequenceLength(input[pos]) catch break;
        if (pos + len > input.len) break;
        const cp = std.unicode.utf8Decode(input[pos .. pos + len]) catch break;

        std.debug.print("  Position {}: byte offset {}, char U+{X:0>4}\n", .{ pos_num, pos, cp });

        pos += len;
        pos_num += 1;
    }

    std.debug.print("\nWord boundaries:\n", .{});
    std.debug.print("  Position 0 (start): should be boundary (nothing before, Ö after)\n", .{});
    std.debug.print("  Position 2 (between Ö and y): both are word chars, NOT a boundary\n", .{});

    std.debug.print("\nTrying to match:\n", .{});
    var re = try Regex.compile(allocator, pattern);
    defer re.deinit();

    const result = try re.isMatch(input);
    std.debug.print("  Match result: {}\n", .{result});
    std.debug.print("  Expected: true (according to Test 90)\n", .{});

    std.debug.print("\nAnalysis:\n", .{});
    std.debug.print("  Pattern \\byster looks for word boundary + 'yster'\n", .{});
    std.debug.print("  In 'Öyster', there's no boundary before 'yster'\n", .{});
    std.debug.print("  Both Ö and y are word characters\n", .{});
    std.debug.print("  So the match SHOULD fail (return false)\n", .{});

    std.debug.print("\nConclusion: Test 90 expected result might be incorrect\n", .{});
}
