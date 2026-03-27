const std = @import("std");

pub const Capture = struct {
    start: usize = 0,
    end: usize = 0,
    matched: bool = false,
    text: []const u8 = "",
};

pub const MatchBuffer = struct {
    allocator: std.mem.Allocator,
    start: usize = 0,
    end: usize = 0,
    slice: []const u8 = "",
    matched: bool = false,
    captures: []Capture,

    pub fn init(allocator: std.mem.Allocator, capture_count: usize) !MatchBuffer {
        const captures = try allocator.alloc(Capture, capture_count);
        var buffer = MatchBuffer{
            .allocator = allocator,
            .captures = captures,
        };
        buffer.reset();
        return buffer;
    }

    pub fn deinit(self: *MatchBuffer) void {
        self.allocator.free(self.captures);
        self.captures = &[_]Capture{};
        self.reset();
    }

    pub fn reset(self: *MatchBuffer) void {
        self.start = 0;
        self.end = 0;
        self.slice = "";
        self.matched = false;
        for (self.captures) |*capture| {
            capture.* = .{};
        }
    }
};
