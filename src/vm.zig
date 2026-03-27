const std = @import("std");
const bytecode = @import("bytecode.zig");
const common = @import("common.zig");
const errors = @import("errors.zig");
const unicode = @import("unicode.zig");
const text_policy = @import("text_policy.zig");

/// A single node in the linked-list of capture updates
const CaptureNode = struct {
    pos: usize,
    group_id: u8,
    next: ?usize, // Index of parent node in the pool
};

/// Thread in the Thompson NFA simulation
const Thread = struct {
    pc: usize,
    cap_idx: ?usize, // Index of the head capture node in the pool
};

pub const MatchResult = struct {
    start: usize,
    end: usize,
    captures: []Capture,

    pub const Capture = struct {
        start: usize,
        end: usize,
        text: []const u8,
    };

    pub fn deinit(self: MatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.captures);
    }
};

pub const BytecodeVM = struct {
    allocator: std.mem.Allocator,
    prog: bytecode.BytecodeProgram,
    word_boundary_policy: text_policy.WordBoundaryPolicy,

    // Reused buffers keep the hot path allocation-free in the common case.
    current_threads: std.ArrayListUnmanaged(Thread),
    next_threads: std.ArrayListUnmanaged(Thread),
    visited: []bool,
    capture_pool: std.ArrayListUnmanaged(CaptureNode),

    pub fn init(allocator: std.mem.Allocator, prog: bytecode.BytecodeProgram, word_boundary_policy: text_policy.WordBoundaryPolicy) !BytecodeVM {
        const inst_count = prog.instructions.len;
        const current_threads = try std.ArrayListUnmanaged(Thread).initCapacity(allocator, inst_count);
        const next_threads = try std.ArrayListUnmanaged(Thread).initCapacity(allocator, inst_count);
        const visited = try allocator.alloc(bool, inst_count);
        const initial_capture_capacity = @max(inst_count * @max(prog.capture_count, 1), 16);
        const capture_pool = try std.ArrayListUnmanaged(CaptureNode).initCapacity(allocator, initial_capture_capacity);

        return .{
            .allocator = allocator,
            .prog = prog,
            .word_boundary_policy = word_boundary_policy,
            .current_threads = current_threads,
            .next_threads = next_threads,
            .visited = visited,
            .capture_pool = capture_pool,
        };
    }

    pub fn deinit(self: *BytecodeVM) void {
        self.current_threads.deinit(self.allocator);
        self.next_threads.deinit(self.allocator);
        self.allocator.free(self.visited);
        self.capture_pool.deinit(self.allocator);
    }

    fn addThread(self: *BytecodeVM, threads: *std.ArrayListUnmanaged(Thread), pc: usize, cap_idx: ?usize, pos: usize, input: []const u8) !void {
        if (self.visited[pc]) return;
        self.visited[pc] = true;

        const inst = self.prog.instructions[pc];
        switch (inst.op) {
            .jmp => try self.addThread(threads, @intCast(@as(i32, @intCast(pc)) + inst.arg), cap_idx, pos, input),
            .split => {
                try self.addThread(threads, pc + 1, cap_idx, pos, input);
                try self.addThread(threads, @intCast(@as(i32, @intCast(pc)) + inst.arg), cap_idx, pos, input);
            },
            .save => {
                const node_idx = try self.appendCaptureNode(.{ .pos = pos, .group_id = @intCast(inst.arg), .next = cap_idx });
                try self.addThread(threads, pc + 1, node_idx, pos, input);
            },
            .anchor => {
                const anchor_type: @import("ast.zig").AnchorType = @enumFromInt(@as(u8, @intCast(inst.arg >> 1)));
                const multiline = (inst.arg & 1) != 0;

                const matched = switch (anchor_type) {
                    .start_line => pos == 0 or (multiline and text_policy.isLineBreakBefore(input, pos)),
                    .end_line => pos == input.len or (multiline and text_policy.isLineBreakAt(input, pos)),
                    .start_text => pos == 0,
                    .end_text => pos == input.len,
                    .word_boundary => text_policy.isWordBoundary(input, pos, self.word_boundary_policy),
                    .non_word_boundary => text_policy.isNonWordBoundary(input, pos, self.word_boundary_policy),
                };

                if (matched) {
                    try self.addThread(threads, pc + 1, cap_idx, pos, input);
                }
            },
            else => {
                try threads.append(self.allocator, .{ .pc = pc, .cap_idx = cap_idx });
            },
        }
    }

    pub fn matchAt(self: *BytecodeVM, input: []const u8, start_pos: usize, captures: ?*MatchResult) !bool {
        self.current_threads.clearRetainingCapacity();
        self.next_threads.clearRetainingCapacity();
        @memset(self.visited, false);
        self.capture_pool.clearRetainingCapacity();

        var best_end: ?usize = null;
        var best_cap_idx: ?usize = null;

        try self.addThread(&self.current_threads, 0, null, start_pos, input);

        var pos = start_pos;
        while (pos <= input.len) {
            if (self.current_threads.items.len == 0) break;

            @memset(self.visited, false);

            for (self.current_threads.items) |thread| {
                const inst = self.prog.instructions[thread.pc];

                if (inst.op == .match) {
                    best_end = pos;
                    best_cap_idx = thread.cap_idx;
                    // For capturing match, we keep going to find LONGEST match?
                    // Standard Thompson usually takes the FIRST match that reaches .match.
                    // But for regex.find, we want the longest?
                    // Actually, Thompson naturally finds all matches, and we take the last one seen if multiple match at the same 'pos'.
                    if (captures == null) return true;
                    continue;
                }

                if (pos >= input.len) continue;

                const utf8 = unicode.decodeUtf8(input[pos..]) catch return errors.RegexError.InvalidUtf8;

                const matched = switch (inst.op) {
                    .char => blk: {
                        const arg: u32 = @intCast(@as(i32, @intCast(inst.arg)));
                        const target: unicode.Codepoint = @intCast(arg & 0x1FFFFF);
                        const ignore_case = (arg >> 21) != 0;

                        if (ignore_case) {
                            break :blk unicode.toLower(target) == unicode.toLower(utf8.codepoint);
                        } else {
                            break :blk target == utf8.codepoint;
                        }
                    },
                    .any => if (inst.arg == 1) true else utf8.codepoint != '\n',
                    .char_class => self.prog.classes[@intCast(inst.arg)].matches(utf8.codepoint),
                    else => false,
                };

                if (matched) {
                    try self.addThread(&self.next_threads, thread.pc + 1, thread.cap_idx, pos + utf8.len, input);
                }
            }

            if (self.next_threads.items.len == 0) break;

            const tmp = self.current_threads;
            self.current_threads = self.next_threads;
            self.next_threads = tmp;
            self.next_threads.clearRetainingCapacity();

            const utf8_step = unicode.decodeUtf8(input[pos..]) catch break;
            pos += utf8_step.len;
        }

        if (best_end) |end| {
            if (captures) |c| {
                const caps = try self.allocator.alloc(MatchResult.Capture, self.prog.capture_count);
                @memset(caps, .{ .start = 0, .end = 0, .text = "" });

                var curr = best_cap_idx;
                while (curr) |idx| {
                    const node = self.capture_pool.items[idx];
                    const group_id: usize = node.group_id / 2;
                    const is_end = (node.group_id % 2) != 0;

                    if (is_end) {
                        caps[group_id].end = node.pos;
                    } else {
                        caps[group_id].start = node.pos;
                    }
                    curr = node.next;
                }

                for (caps) |*cap| {
                    if (cap.end >= cap.start) {
                        cap.text = input[cap.start..cap.end];
                    }
                }

                c.* = .{ .start = start_pos, .end = end, .captures = caps };
            }
            return true;
        }

        return false;
    }

    fn appendCaptureNode(self: *BytecodeVM, node: CaptureNode) !usize {
        const idx = self.capture_pool.items.len;
        try self.capture_pool.append(self.allocator, node);
        return idx;
    }
};
