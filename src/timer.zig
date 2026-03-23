const std = @import("std");
const builtin = @import("builtin");

/// Cross-platform high-resolution timer for Zig 0.16
pub const Timer = struct {
    start_time: i64,

    pub fn start() !Timer {
        return .{ .start_time = try now() };
    }

    pub fn read(self: Timer) !i64 {
        const current = try now();
        return current - self.start_time;
    }

    /// Get current timestamp in nanoseconds
    pub fn timestamp() !i64 {
        return try now();
    }

    fn now() !i64 {
        return switch (builtin.os.tag) {
            .windows => nowWindows(),
            .linux => nowLinux(),
            .macos => nowMacos(),
            else => error.UnsupportedOS,
        };
    }

    fn nowWindows() !i64 {
        const windows = std.os.windows;
        var frequency: windows.LARGE_INTEGER = undefined;
        var counter: windows.LARGE_INTEGER = undefined;
        if (windows.ntdll.RtlQueryPerformanceFrequency(&frequency) == 0) return error.QueryPerformanceFailed;
        _ = windows.ntdll.RtlQueryPerformanceCounter(&counter);
        const freq: i64 = @bitCast(frequency);
        const cnt: i64 = @bitCast(counter);
        // Use i128 to avoid overflow when multiplying by 1 billion
        const cnt_128: i128 = cnt;
        const result: i128 = @divTrunc(cnt_128 * 1_000_000_000, freq);
        return @intCast(result);
    }

    fn nowLinux() !i64 {
        var ts: std.os.linux.timespec = undefined;
        const rc = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        if (rc != 0) return error.ClockGetTimeFailed;
        return @as(i64, ts.tv_sec) * 1_000_000_000 + ts.tv_nsec;
    }

    fn nowMacos() !i64 {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return error.ClockGetTimeFailed;
        return @as(i64, ts.tv_sec) * 1_000_000_000 + @as(i64, ts.tv_nsec);
    }
};
