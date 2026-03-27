const std = @import("std");
const bytecode = @import("bytecode.zig");
const common = @import("common.zig");
const errors = @import("errors.zig");
const unicode = @import("unicode.zig");
const text_policy = @import("text_policy.zig");
const match_types = @import("match_types.zig");

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
    trusted_utf8: bool,

    // Reused buffers keep the hot path allocation-free in the common case.
    current_threads: std.ArrayListUnmanaged(Thread),
    next_threads: std.ArrayListUnmanaged(Thread),
    visited: []bool,
    capture_pool: std.ArrayListUnmanaged(CaptureNode),

    pub fn init(allocator: std.mem.Allocator, prog: bytecode.BytecodeProgram, word_boundary_policy: text_policy.WordBoundaryPolicy, trusted_utf8: bool) !BytecodeVM {
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
            .trusted_utf8 = trusted_utf8,
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
                    .end_text_strict => text_policy.isAbsoluteEnd(input, pos),
                    .end_text_before_final_newline => text_policy.isEndBeforeFinalNewline(input, pos),
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

    const SearchResult = struct {
        end: usize,
        cap_idx: ?usize,
    };

    pub fn matchAt(self: *BytecodeVM, input: []const u8, start_pos: usize, captures: ?*MatchResult) !bool {
        const result = try self.searchMatchAt(input, start_pos, captures == null) orelse return false;

        if (captures) |c| {
            const caps = try self.allocator.alloc(MatchResult.Capture, self.prog.capture_count);
            self.populateOwnedCaptures(input, result.cap_idx, caps);
            c.* = .{ .start = start_pos, .end = result.end, .captures = caps };
        }

        return true;
    }

    pub fn matchAtInto(self: *BytecodeVM, input: []const u8, start_pos: usize, captures: []match_types.Capture, end_out: *usize) !bool {
        if (captures.len != self.prog.capture_count) return errors.RegexError.InvalidArgument;

        const result = try self.searchMatchAt(input, start_pos, false) orelse return false;
        self.populateBorrowedCaptures(input, result.cap_idx, captures);
        end_out.* = result.end;
        return true;
    }

    fn decodeAt(self: *BytecodeVM, input: []const u8, pos: usize) !unicode.Utf8DecodeResult {
        if (self.trusted_utf8) {
            return unicode.decodeUtf8Trusted(input, pos);
        }
        return unicode.decodeUtf8(input[pos..]) catch return errors.RegexError.InvalidUtf8;
    }

    fn searchMatchAt(self: *BytecodeVM, input: []const u8, start_pos: usize, stop_on_first_match: bool) !?SearchResult {
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

            const utf8 = if (pos < input.len) try self.decodeAt(input, pos) else null;

            for (self.current_threads.items) |thread| {
                const inst = self.prog.instructions[thread.pc];

                if (inst.op == .match) {
                    if (stop_on_first_match) {
                        return .{ .end = pos, .cap_idx = thread.cap_idx };
                    }
                    best_end = pos;
                    best_cap_idx = thread.cap_idx;
                    continue;
                }

                const decoded = utf8 orelse continue;

                const matched = switch (inst.op) {
                    .char => blk: {
                        const arg: u32 = @intCast(@as(i32, @intCast(inst.arg)));
                        const target: unicode.Codepoint = @intCast(arg & 0x1FFFFF);
                        const ignore_case = (arg >> 21) != 0;

                        if (ignore_case) {
                            break :blk unicode.toLower(target) == unicode.toLower(decoded.codepoint);
                        } else {
                            break :blk target == decoded.codepoint;
                        }
                    },
                    .any => if (inst.arg == 1) true else decoded.codepoint != '\n',
                    .char_class => self.prog.classes[@intCast(inst.arg)].matches(decoded.codepoint),
                    else => false,
                };

                if (matched) {
                    try self.addThread(&self.next_threads, thread.pc + 1, thread.cap_idx, pos + decoded.len, input);
                }
            }

            if (self.next_threads.items.len == 0) break;

            const tmp = self.current_threads;
            self.current_threads = self.next_threads;
            self.next_threads = tmp;
            self.next_threads.clearRetainingCapacity();

            const step = utf8 orelse break;
            pos += step.len;
        }

        if (best_end) |end| {
            return .{ .end = end, .cap_idx = best_cap_idx };
        }

        return null;
    }

    fn populateOwnedCaptures(self: *BytecodeVM, input: []const u8, cap_idx: ?usize, captures: []MatchResult.Capture) void {
        @memset(captures, .{ .start = 0, .end = 0, .text = "" });

        var curr = cap_idx;
        while (curr) |idx| {
            const node = self.capture_pool.items[idx];
            const group_id: usize = node.group_id / 2;
            const is_end = (node.group_id % 2) != 0;

            if (is_end) {
                captures[group_id].end = node.pos;
            } else {
                captures[group_id].start = node.pos;
            }
            curr = node.next;
        }

        for (captures) |*capture| {
            if (capture.end >= capture.start) {
                capture.text = input[capture.start..capture.end];
            }
        }
    }

    fn populateBorrowedCaptures(self: *BytecodeVM, input: []const u8, cap_idx: ?usize, captures: []match_types.Capture) void {
        for (captures) |*capture| {
            capture.* = .{};
        }

        var curr = cap_idx;
        while (curr) |idx| {
            const node = self.capture_pool.items[idx];
            const group_id: usize = node.group_id / 2;
            const is_end = (node.group_id % 2) != 0;

            if (is_end) {
                captures[group_id].end = node.pos;
            } else {
                captures[group_id].start = node.pos;
            }
            captures[group_id].matched = true;
            curr = node.next;
        }

        for (captures) |*capture| {
            if (capture.end >= capture.start) {
                capture.text = input[capture.start..capture.end];
            }
        }
    }

    fn appendCaptureNode(self: *BytecodeVM, node: CaptureNode) !usize {
        const idx = self.capture_pool.items.len;
        try self.capture_pool.append(self.allocator, node);
        return idx;
    }
};
