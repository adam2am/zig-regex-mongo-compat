const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");

// ============================================================================
// 1. INSTRUCTION SET ARCHITECTURE (ISA)
// ============================================================================
// We use a 32-bit instruction. 
// - 8 bits for the Opcode.
// - 24 bits for the Payload (Offset or Character).
// This fits perfectly into the CPU's L1 instruction cache.

pub const Opcode = enum(u8) {
    /// Match a single character. arg = codepoint.
    char = 0,
    /// Match any character (.).
    any = 1,
    /// Split execution. Push (IP + arg) to backtrack stack, continue to IP + 1.
    split = 2,
    /// Unconditional jump. IP = IP + arg.
    jmp = 3,
    /// Save capture group boundary. arg = capture_index * 2 (+1 if end).
    save = 4,
    /// Successfully matched the pattern.
    match = 5,
    
    // Future additions: class, lookahead, backref, assert_word_boundary, etc.
};

pub const Inst = packed struct {
    op: Opcode,
    arg: u24 = 0,
};

// ============================================================================
// 2. THE COMPILER
// ============================================================================
// Flattens the AST into a `[]Inst` array.

pub const BytecodeProgram = struct {
    instructions: []Inst,
    capture_count: usize,

    pub fn deinit(self: *BytecodeProgram, allocator: std.mem.Allocator) void {
        allocator.free(self.instructions);
    }
};

pub const BytecodeCompiler = struct {
    allocator: std.mem.Allocator,
    insts: std.ArrayList(Inst),
    capture_count: usize,

    pub fn init(allocator: std.mem.Allocator, capture_count: usize) BytecodeCompiler {
        return .{
            .allocator = allocator,
            .insts = std.ArrayList(Inst).initCapacity(allocator, 128) catch unreachable,
            .capture_count = capture_count,
        };
    }

    pub fn deinit(self: *BytecodeCompiler) void {
        self.insts.deinit();
    }

    /// Appends an instruction and returns its index (useful for backpatching)
    fn emit(self: *BytecodeCompiler, op: Opcode, arg: u24) !usize {
        const idx = self.insts.items.len;
        try self.insts.append(.{ .op = op, .arg = arg });
        return idx;
    }

    /// Patches the argument of a previously emitted instruction (used for forward jumps)
    fn patch(self: *BytecodeCompiler, inst_idx: usize, target_idx: usize) void {
        // We store relative offsets. +1 because IP automatically advances in the VM.
        const offset = target_idx - inst_idx; 
        self.insts.items[inst_idx].arg = @intCast(offset);
    }

    pub fn compile(self: *BytecodeCompiler, root: *ast.Node) !BytecodeProgram {
        try self.compileNode(root);
        _ = try self.emit(.match, 0); // Always end with a success opcode

        return BytecodeProgram{
            .instructions = try self.insts.toOwnedSlice(),
            .capture_count = self.capture_count,
        };
    }

    fn compileNode(self: *BytecodeCompiler, node: *ast.Node) !void {
        switch (node.node_type) {
            .literal => {
                _ = try self.emit(.char, @intCast(node.data.literal.c));
            },
            .any => {
                _ = try self.emit(.any, 0);
            },
            .concat => {
                try self.compileNode(node.data.concat.left);
                try self.compileNode(node.data.concat.right);
            },
            .alternation => {
                // e.g., A | B
                // L1: split L2
                //     compile(A)
                //     jmp L3
                // L2: compile(B)
                // L3: ...
                const split_idx = try self.emit(.split, 0);
                
                try self.compileNode(node.data.alternation.left);
                
                const jmp_idx = try self.emit(.jmp, 0);
                
                self.patch(split_idx, self.insts.items.len); // L2
                
                try self.compileNode(node.data.alternation.right);
                
                self.patch(jmp_idx, self.insts.items.len); // L3
            },
            .star => {
                // e.g., A* (Greedy)
                // L1: split L2
                //     compile(A)
                //     jmp L1
                // L2: ...
                const L1 = self.insts.items.len;
                const split_idx = try self.emit(.split, 0);
                
                try self.compileNode(node.data.star.child);
                
                // Let's implement negative jumps by interpreting the 24-bit arg as an absolute IP address 
                // OR two's complement. Let's just use Absolute Addressing for jumps to keep it simple!
                
                // *REVISED JMP LOGIC: arg is an ABSOLUTE IP address, not relative.*
                self.insts.items[split_idx].arg = @intCast(L1); 
                return error.NotImplementedYet; 
            },
            .group => {
                if (node.data.group.capture_index) |idx| {
                    // save(2 * idx) -> marks start
                    _ = try self.emit(.save, @intCast(idx * 2));
                    try self.compileNode(node.data.group.child);
                    // save(2 * idx + 1) -> marks end
                    _ = try self.emit(.save, @intCast(idx * 2 + 1));
                } else {
                    try self.compileNode(node.data.group.child);
                }
            },
            else => return error.NotImplementedYet,
        }
    }
};

// ============================================================================
// 3. THE VIRTUAL MACHINE
// ============================================================================

pub const VMResult = struct {
    matched: bool,
    end_pos: usize,
    captures: []?usize, // Flattened array: [start1, end1, start2, end2...]
};

pub const BytecodeVM = struct {
    allocator: std.mem.Allocator,
    prog: *const BytecodeProgram,
    
    // A single backtracking thread state
    const Frame = struct {
        ip: usize,
        sp: usize,
        // We must snapshot capture states on branching.
        // For V1, we store a pointer to a cloned array. 
        // In V2, we optimize this to an O(1) history log.
        captures: []?usize, 
    };

    pub fn init(allocator: std.mem.Allocator, prog: *const BytecodeProgram) BytecodeVM {
        return .{
            .allocator = allocator,
            .prog = prog,
        };
    }

    pub fn matchAt(self: *BytecodeVM, input: []const u8, start_pos: usize) !VMResult {
        var ip: usize = 0;
        var sp: usize = start_pos;
        
        // captures[0] = group1 start, captures[1] = group1 end, etc.
        var captures = try self.allocator.alloc(?usize, self.prog.capture_count * 2);
        @memset(captures, null);
        defer self.allocator.free(captures);

        var stack = std.ArrayList(Frame).initCapacity(self.allocator, 128) catch unreachable;
        defer {
            for (stack.items) |frame| self.allocator.free(frame.captures);
            stack.deinit();
        }

        var step_count: usize = 0;

        while (true) {
            step_count += 1;
            if (step_count > 10_000_000) return error.CatastrophicBacktracking;

            const inst = self.prog.instructions[ip];

            switch (inst.op) {
                .char => {
                    // Fast decode 1 byte if ASCII, else fallback to UTF8
                    if (sp < input.len and input[sp] == inst.arg) {
                        ip += 1;
                        sp += 1;
                    } else {
                        // FAIL: Backtrack
                        if (stack.items.len == 0) return VMResult{ .matched = false, .end_pos = 0, .captures = &[_]?usize{} };
                        const frame = stack.pop();
                        ip = frame.ip;
                        sp = frame.sp;
                        @memcpy(captures, frame.captures);
                        self.allocator.free(frame.captures);
                    }
                },
                .any => {
                    if (sp < input.len) {
                        // Simplified: Assume 1 byte for now. Add UTF8 decoding logic here.
                        ip += 1;
                        sp += 1;
                    } else {
                        if (stack.items.len == 0) return VMResult{ .matched = false, .end_pos = 0, .captures = &[_]?usize{} };
                        const frame = stack.pop();
                        ip = frame.ip;
                        sp = frame.sp;
                        @memcpy(captures, frame.captures);
                        self.allocator.free(frame.captures);
                    }
                },
                .split => {
                    // Push the alternative branch to the stack
                    const snapshot = try self.allocator.dupe(?usize, captures);
                    try stack.append(.{
                        .ip = ip + inst.arg, // Absolute or relative? Let's assume relative forward jump for now.
                        .sp = sp,
                        .captures = snapshot,
                    });
                    // Continue down primary branch
                    ip += 1;
                },
                .jmp => {
                    ip += inst.arg; // Jump forward
                },
                .save => {
                    captures[inst.arg] = sp;
                    ip += 1;
                },
                .match => {
                    // SUCCESS!
                    const final_caps = try self.allocator.dupe(?usize, captures);
                    return VMResult{
                        .matched = true,
                        .end_pos = sp,
                        .captures = final_caps,
                    };
                },
            }
        }
    }
};
