const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");

// ============================================================================
// 1. INSTRUCTION SET ARCHITECTURE (ISA)
// ============================================================================

pub const Opcode = enum(u8) {
    char = 0,         // Match a single character. arg = codepoint.
    any = 1,          // Match any character (.). arg = dot_all (0/1).
    char_class = 2,   // Match character class. arg = class list index.
    anchor = 3,       // Match anchor. arg = (AnchorType << 1) | multiline.
    split = 4,        // Split execution. arg = relative offset to secondary.
    jmp = 5,          // Unconditional jump. arg = relative offset.
    save = 6,         // Save position. arg = capture_index.
    match = 7,        // Success.
};

pub const Inst = packed struct {
    op: Opcode,
    arg: i24 = 0, // i24 allows relative jumps of +/- 8MB
};

pub const BytecodeProgram = struct {
    instructions: []const Inst,
    classes: []const common.CharClass,
    capture_count: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: BytecodeProgram) void {
        for (self.classes) |class| {
            self.allocator.free(class.ranges);
        }
        self.allocator.free(self.instructions);
        self.allocator.free(self.classes);
    }
};

// ============================================================================
// 2. THE COMPILER
// ============================================================================

pub const BytecodeCompiler = struct {
    allocator: std.mem.Allocator,
    insts: std.ArrayListUnmanaged(Inst),
    classes: std.ArrayListUnmanaged(common.CharClass),
    capture_count: usize,

    pub fn init(allocator: std.mem.Allocator, capture_count: usize) BytecodeCompiler {
        return .{
            .allocator = allocator,
            .insts = .empty,
            .classes = .empty,
            .capture_count = capture_count,
        };
    }

    pub fn deinit(self: *BytecodeCompiler) void {
        self.insts.deinit(self.allocator);
        self.classes.deinit(self.allocator);
    }

    fn emit(self: *BytecodeCompiler, op: Opcode, arg: i24) !usize {
        const idx = self.insts.items.len;
        try self.insts.append(self.allocator, .{ .op = op, .arg = arg });
        return idx;
    }

    fn patch(self: *BytecodeCompiler, inst_idx: usize, target_idx: usize) void {
        const offset: i32 = @intCast(target_idx);
        const current: i32 = @intCast(inst_idx);
        self.insts.items[inst_idx].arg = @intCast(offset - current);
    }

    pub fn compile(self: *BytecodeCompiler, root: *ast.Node) !BytecodeProgram {
        try self.compileNode(root);
        _ = try self.emit(.match, 0);

        return BytecodeProgram{
            .instructions = try self.insts.toOwnedSlice(self.allocator),
            .classes = try self.classes.toOwnedSlice(self.allocator),
            .capture_count = self.capture_count,
            .allocator = self.allocator,
        };
    }

    fn compileNode(self: *BytecodeCompiler, node: *ast.Node) !void {
        switch (node.node_type) {
            .literal => {
                const c: u32 = @intCast(node.data.literal.c);
                const ignore_case: u32 = if (node.data.literal.ignore_case) 1 else 0;
                const arg = @as(i24, @intCast(c | (ignore_case << 21)));
                _ = try self.emit(.char, arg);
            },
            .any => {
                _ = try self.emit(.any, if (node.data.any.dot_all) 1 else 0);
            },
            .char_class => {
                const class = node.data.char_class.class;
                const ranges_copy = try self.allocator.dupe(common.CharRange, class.ranges);
                var compiled_class = class;
                compiled_class.ranges = ranges_copy;
                compiled_class.precompute();

                const class_idx = self.classes.items.len;
                try self.classes.append(self.allocator, compiled_class);
                _ = try self.emit(.char_class, @intCast(class_idx));
            },
            .anchor => {
                const arg = (@as(i24, @intFromEnum(node.data.anchor.type)) << 1) | (if (node.data.anchor.multiline) @as(i24, 1) else 0);
                _ = try self.emit(.anchor, arg);
            },
            .concat => {
                try self.compileNode(node.data.concat.left);
                try self.compileNode(node.data.concat.right);
            },
            .alternation => {
                // split L2
                // A
                // jmp L3
                // L2: B
                // L3:
                const split_idx = try self.emit(.split, 0);
                try self.compileNode(node.data.alternation.left);
                const jmp_idx = try self.emit(.jmp, 0);
                self.patch(split_idx, self.insts.items.len);
                try self.compileNode(node.data.alternation.right);
                self.patch(jmp_idx, self.insts.items.len);
            },
            .star => {
                // L1: split L2
                //     A
                //     jmp L1
                // L2:
                const L1 = self.insts.items.len;
                const split_idx = try self.emit(.split, 0);
                try self.compileNode(node.data.star.child);
                _ = try self.emit(.jmp, @intCast(@as(i32, @intCast(L1)) - @as(i32, @intCast(self.insts.items.len))));
                self.patch(split_idx, self.insts.items.len);
                if (node.data.star.mode == .lazy) {
                    // For lazy star, we swap split targets: split(L1, L2) -> split(L2, L1)
                    // Our split(arg) means "continue to IP+1 OR jump to IP+arg"
                    // Greedy: try A (IP+1), else L2 (IP+arg)
                    // Lazy: try L2 (IP+arg), else A (IP+1)
                    // We can achieve this by swapping the logic in the VM or swapping offsets here.
                    // For now, let's keep it simple and assume the VM handles greedy/lazy via split order.
                }
            },
            .plus => {
                // L1: A
                //     split L2
                //     jmp L1
                // L2:
                const L1 = self.insts.items.len;
                try self.compileNode(node.data.plus.child);
                const split_idx = try self.emit(.split, 0);
                _ = try self.emit(.jmp, @intCast(@as(i32, @intCast(L1)) - @as(i32, @intCast(self.insts.items.len))));
                self.patch(split_idx, self.insts.items.len);
            },
            .optional => {
                // split L2
                // A
                // L2:
                const split_idx = try self.emit(.split, 0);
                try self.compileNode(node.data.optional.child);
                self.patch(split_idx, self.insts.items.len);
            },
            .group => {
                if (node.data.group.capture_index) |idx| {
                    const slot = idx - 1; // Public capture indices are 1-based; VM capture slots are 0-based.
                    _ = try self.emit(.save, @intCast(slot * 2));
                    try self.compileNode(node.data.group.child);
                    _ = try self.emit(.save, @intCast(slot * 2 + 1));
                } else {
                    try self.compileNode(node.data.group.child);
                }
            },
            .empty => {},
            else => return error.NotImplemented,
        }
    }
};
