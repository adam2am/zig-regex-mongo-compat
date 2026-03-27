const std = @import("std");
const regex_mod = @import("regex");
const Regex = regex_mod.Regex;
const Parser = regex_mod.parser.Parser;
const BacktrackEngine = regex_mod.backtrack.BacktrackEngine;
const CompileFlags = regex_mod.common.CompileFlags;
const WordBoundaryPolicy = regex_mod.text_policy.WordBoundaryPolicy;

fn appendRandomAtom(random: std.Random, allocator: std.mem.Allocator, out: *std.ArrayList(u8), allow_anchor: bool) !void {
    const atoms = [_][]const u8{
        "a", "b", "c", "x", "y", "z",
        ".", "\\d", "\\w", "[ab]", "[a-c]", "[^x]",
        "(ab)", "(a|b)", "(?:ab)",
    };
    const anchors = [_][]const u8{ "^", "$" };
    const quantifiers = [_][]const u8{ "", "*", "+", "?" };

    if (allow_anchor and random.boolean()) {
        try out.appendSlice(allocator, anchors[random.uintLessThan(usize, anchors.len)]);
    }

    const atom = atoms[random.uintLessThan(usize, atoms.len)];
    try out.appendSlice(allocator, atom);

    const quant = quantifiers[random.uintLessThan(usize, quantifiers.len)];
    try out.appendSlice(allocator, quant);
}

fn generatePattern(random: std.Random, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const use_alternation = random.boolean();
    const left_count = random.intRangeAtMost(usize, 1, 3);
    for (0..left_count) |idx| {
        try appendRandomAtom(random, allocator, &out, idx == 0);
    }

    if (use_alternation) {
        try out.append(allocator, '|');
        const right_count = random.intRangeAtMost(usize, 1, 3);
        for (0..right_count) |idx| {
            try appendRandomAtom(random, allocator, &out, idx == 0);
        }
    }

    return out.toOwnedSlice(allocator);
}

fn generateInput(random: std.Random, allocator: std.mem.Allocator) ![]u8 {
    const alphabet = [_][]const u8{ "a", "b", "c", "x", "y", "z", "0", "1", "2", "\n" };
    const len = random.intRangeAtMost(usize, 0, 10);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (0..len) |_| {
        const piece = alphabet[random.uintLessThan(usize, alphabet.len)];
        try out.appendSlice(allocator, piece);
    }

    return out.toOwnedSlice(allocator);
}

test "differential: thompson and backtracking agree on shared subset" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xD1FF3E71);
    const random = prng.random();

    const pattern_iterations = 80;
    const input_iterations = 12;

    var pattern_index: usize = 0;
    while (pattern_index < pattern_iterations) : (pattern_index += 1) {
        const pattern = try generatePattern(random, allocator);
        defer allocator.free(pattern);

        var compiled = Regex.compileWithFlags(allocator, pattern, CompileFlags{}) catch continue;
        defer compiled.deinit();

        if (compiled.engine_type != .thompson_nfa) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = try Parser.init(arena.allocator(), pattern, CompileFlags{});
        var tree = try parser.parse();
        defer tree.deinit();

        var backtrack = try BacktrackEngine.init(allocator, tree.root, tree.capture_count, CompileFlags{}, null, WordBoundaryPolicy.ascii_default);
        defer backtrack.deinit();

        var input_index: usize = 0;
        while (input_index < input_iterations) : (input_index += 1) {
            const input = try generateInput(random, allocator);
            defer allocator.free(input);

            const nfa_result = try compiled.isMatch(input);
            const backtrack_result = try backtrack.isMatch(input);

            if (nfa_result != backtrack_result) {
                std.debug.print("DIFF pattern={s} input={s} nfa={} backtrack={}\n", .{ pattern, input, nfa_result, backtrack_result });
                return error.TestUnexpectedResult;
            }
        }
    }
}
