const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const pattern_analyzer = @import("pattern_analyzer.zig");
const text_policy = @import("text_policy.zig");

pub const EngineType = enum {
    thompson_nfa,
    backtracking,
};

pub const InputValidationPolicy = enum {
    strict_utf8,
    engine_defined,
};

pub const FeatureAnalysis = struct {
    requires_backtracking: bool,
    uses_extended_grapheme: bool,
    has_nested_quantifiers: bool,
    all_nested_quantifiers_bounded: bool,
};

pub const ExecutionPlan = struct {
    engine_type: EngineType,
    input_validation_policy: InputValidationPolicy,
    word_boundary_policy: text_policy.WordBoundaryPolicy,
    analyzer_max_risk: ?pattern_analyzer.RiskLevel,
};

pub fn analyzeFeatures(root: *ast.Node, flags: common.CompileFlags) FeatureAnalysis {
    _ = flags;
    return .{
        .requires_backtracking = requiresBacktracking(root),
        .uses_extended_grapheme = containsExtendedGrapheme(root),
        .has_nested_quantifiers = containsNestedQuantifiers(root),
        .all_nested_quantifiers_bounded = allQuantifiersBounded(root),
    };
}

pub fn build(root: *ast.Node, flags: common.CompileFlags) ExecutionPlan {
    const analysis = analyzeFeatures(root, flags);
    return .{
        .engine_type = if (analysis.requires_backtracking) .backtracking else .thompson_nfa,
        .input_validation_policy = if (analysis.uses_extended_grapheme) .engine_defined else .strict_utf8,
        .word_boundary_policy = text_policy.fromFlags(flags),
        .analyzer_max_risk = if (analysis.requires_backtracking and analysis.has_nested_quantifiers and !analysis.all_nested_quantifiers_bounded) .medium else null,
    };
}

fn requiresBacktracking(node: *ast.Node) bool {
    return switch (node.node_type) {
        .literal, .any, .char_class, .anchor, .empty => false,
        .concat => requiresBacktracking(node.data.concat.left) or requiresBacktracking(node.data.concat.right),
        .alternation => requiresBacktracking(node.data.alternation.left) or requiresBacktracking(node.data.alternation.right),
        .star => node.data.star.mode == .possessive or requiresBacktracking(node.data.star.child),
        .plus => node.data.plus.mode == .possessive or requiresBacktracking(node.data.plus.child),
        .optional => node.data.optional.mode == .possessive or requiresBacktracking(node.data.optional.child),
        .repeat => true,
        .group => requiresBacktracking(node.data.group.child),
        .lookahead, .lookbehind, .atomic_group, .conditional, .backref, .extended_grapheme, .recursion => true,
    };
}

fn containsExtendedGrapheme(node: *ast.Node) bool {
    return switch (node.node_type) {
        .extended_grapheme => true,
        .concat => containsExtendedGrapheme(node.data.concat.left) or containsExtendedGrapheme(node.data.concat.right),
        .alternation => containsExtendedGrapheme(node.data.alternation.left) or containsExtendedGrapheme(node.data.alternation.right),
        .star => containsExtendedGrapheme(node.data.star.child),
        .plus => containsExtendedGrapheme(node.data.plus.child),
        .optional => containsExtendedGrapheme(node.data.optional.child),
        .repeat => containsExtendedGrapheme(node.data.repeat.child),
        .group => containsExtendedGrapheme(node.data.group.child),
        .lookahead => containsExtendedGrapheme(node.data.lookahead.child),
        .lookbehind => containsExtendedGrapheme(node.data.lookbehind.child),
        .atomic_group => containsExtendedGrapheme(node.data.atomic_group.child),
        .conditional => blk: {
            const cond = node.data.conditional;
            break :blk containsExtendedGrapheme(cond.yes_branch) or (if (cond.no_branch) |no| containsExtendedGrapheme(no) else false);
        },
        else => false,
    };
}

fn containsNestedQuantifiers(node: *ast.Node) bool {
    return switch (node.node_type) {
        .star, .plus, .optional, .repeat => blk: {
            const child = getQuantifiedChild(node);
            break :blk isQuantifier(child) or containsQuantifier(child) or containsNestedQuantifiers(child);
        },
        .concat => containsNestedQuantifiers(node.data.concat.left) or containsNestedQuantifiers(node.data.concat.right),
        .alternation => containsNestedQuantifiers(node.data.alternation.left) or containsNestedQuantifiers(node.data.alternation.right),
        .group => containsNestedQuantifiers(node.data.group.child),
        .lookahead => containsNestedQuantifiers(node.data.lookahead.child),
        .lookbehind => containsNestedQuantifiers(node.data.lookbehind.child),
        .atomic_group => containsNestedQuantifiers(node.data.atomic_group.child),
        .conditional => blk: {
            const cond = node.data.conditional;
            break :blk containsNestedQuantifiers(cond.yes_branch) or (if (cond.no_branch) |no| containsNestedQuantifiers(no) else false);
        },
        else => false,
    };
}

fn allQuantifiersBounded(node: *ast.Node) bool {
    return switch (node.node_type) {
        .star, .plus, .optional => false,
        .repeat => node.data.repeat.bounds.max != null and allQuantifiersBounded(node.data.repeat.child),
        .concat => allQuantifiersBounded(node.data.concat.left) and allQuantifiersBounded(node.data.concat.right),
        .alternation => allQuantifiersBounded(node.data.alternation.left) and allQuantifiersBounded(node.data.alternation.right),
        .group => allQuantifiersBounded(node.data.group.child),
        .lookahead => allQuantifiersBounded(node.data.lookahead.child),
        .lookbehind => allQuantifiersBounded(node.data.lookbehind.child),
        .atomic_group => allQuantifiersBounded(node.data.atomic_group.child),
        .conditional => blk: {
            const cond = node.data.conditional;
            break :blk allQuantifiersBounded(cond.yes_branch) and (if (cond.no_branch) |no| allQuantifiersBounded(no) else true);
        },
        else => true,
    };
}

fn containsQuantifier(node: *ast.Node) bool {
    return switch (node.node_type) {
        .star, .plus, .optional, .repeat => true,
        .concat => containsQuantifier(node.data.concat.left) or containsQuantifier(node.data.concat.right),
        .alternation => containsQuantifier(node.data.alternation.left) or containsQuantifier(node.data.alternation.right),
        .group => containsQuantifier(node.data.group.child),
        .lookahead => containsQuantifier(node.data.lookahead.child),
        .lookbehind => containsQuantifier(node.data.lookbehind.child),
        .atomic_group => containsQuantifier(node.data.atomic_group.child),
        .conditional => blk: {
            const cond = node.data.conditional;
            break :blk containsQuantifier(cond.yes_branch) or (if (cond.no_branch) |no| containsQuantifier(no) else false);
        },
        else => false,
    };
}

fn isQuantifier(node: *ast.Node) bool {
    return switch (node.node_type) {
        .star, .plus, .optional, .repeat => true,
        else => false,
    };
}

fn getQuantifiedChild(node: *ast.Node) *ast.Node {
    return switch (node.node_type) {
        .star => node.data.star.child,
        .plus => node.data.plus.child,
        .optional => node.data.optional.child,
        .repeat => node.data.repeat.child,
        else => unreachable,
    };
}

test "execution_plan: bounded nested repeats are allowed to plan without analyzer rejection" {
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try parser.Parser.init(allocator, "^(?:a{1,2}){3,4}$", .{});
    var tree = try p.parse();
    defer tree.deinit();

    const plan = build(tree.root, .{});
    try std.testing.expect(plan.engine_type == .backtracking);
    try std.testing.expect(plan.analyzer_max_risk == null);
}
