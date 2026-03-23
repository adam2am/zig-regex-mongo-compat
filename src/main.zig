const std = @import("std");
const regex = @import("root.zig");
const Regex = regex.Regex;

const usage_text =
    \\Usage: regex [options] <pattern> [input]
    \\
    \\A fast regex matching tool built with Zig.
    \\
    \\Arguments:
    \\  <pattern>    Regular expression pattern
    \\  [input]      Input text (reads from stdin if omitted)
    \\
    \\Options:
    \\  -g           Find all matches (global)
    \\  -i           Case-insensitive matching
    \\  -m           Multiline mode (^ and $ match line boundaries)
    \\  -r <repl>    Replace matches with <repl>
    \\  -v           Print version
    \\  -h           Print this help
    \\
;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_w = stdout.writer(&stdout_buf);
    var stderr_w = stderr.writer(&stderr_buf);
    const stdout_writer = &stdout_w.interface;
    const stderr_writer = &stderr_w.interface;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var case_insensitive = false;
    var multiline = false;
    var global = false;
    var replacement: ?[]const u8 = null;
    var pattern_str: ?[]const u8 = null;
    var input_str: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
                try stdout_writer.writeAll("regex 1.0.0\n");
                try stdout_writer.flush();
                return;
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                try stdout_writer.writeAll(usage_text);
                try stdout_writer.flush();
                return;
            } else if (std.mem.eql(u8, arg, "-i")) {
                case_insensitive = true;
            } else if (std.mem.eql(u8, arg, "-m")) {
                multiline = true;
            } else if (std.mem.eql(u8, arg, "-g")) {
                global = true;
            } else if (std.mem.eql(u8, arg, "-r")) {
                i += 1;
                if (i >= args.len) {
                    try stderr_writer.writeAll("error: -r requires a replacement string\n");
                    try stderr_writer.flush();
                    std.process.exit(1);
                }
                replacement = args[i];
            } else {
                try stderr_writer.print("error: unknown option: {s}\n", .{arg});
                try stderr_writer.flush();
                std.process.exit(1);
            }
        } else if (pattern_str == null) {
            pattern_str = arg;
        } else if (input_str == null) {
            input_str = arg;
        }
    }

    const pattern = pattern_str orelse {
        try stdout_writer.writeAll(usage_text);
        try stdout_writer.flush();
        return;
    };

    var stdin_alloc: ?[]u8 = null;
    defer if (stdin_alloc) |buf| allocator.free(buf);

    const input: []const u8 = if (input_str) |s| s else blk: {
        const stdin = std.fs.File.stdin();
        var buffer = std.ArrayList(u8){};
        errdefer buffer.deinit(allocator);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = try stdin.read(&chunk);
            if (n == 0) break;
            try buffer.appendSlice(allocator, chunk[0..n]);
        }
        stdin_alloc = try buffer.toOwnedSlice(allocator);
        break :blk stdin_alloc.?;
    };

    var re = Regex.compileWithFlags(allocator, pattern, .{
        .case_insensitive = case_insensitive,
        .multiline = multiline,
    }) catch |err| {
        try stderr_writer.print("error: invalid pattern: {s}\n", .{@errorName(err)});
        try stderr_writer.flush();
        std.process.exit(1);
    };
    defer re.deinit();

    if (replacement) |repl| {
        const result = if (global)
            re.replaceAll(allocator, input, repl) catch |err| {
                try stderr_writer.print("error: replace failed: {s}\n", .{@errorName(err)});
                try stderr_writer.flush();
                std.process.exit(1);
            }
        else
            re.replace(allocator, input, repl) catch |err| {
                try stderr_writer.print("error: replace failed: {s}\n", .{@errorName(err)});
                try stderr_writer.flush();
                std.process.exit(1);
            };
        defer allocator.free(result);
        try stdout_writer.writeAll(result);
        try stdout_writer.writeAll("\n");
        try stdout_writer.flush();
    } else if (global) {
        const matches = re.findAll(allocator, input) catch |err| {
            try stderr_writer.print("error: match failed: {s}\n", .{@errorName(err)});
            try stderr_writer.flush();
            std.process.exit(1);
        };
        defer {
            for (matches) |*m| {
                var mut_m = m;
                mut_m.deinit(allocator);
            }
            allocator.free(matches);
        }
        if (matches.len == 0) std.process.exit(1);
        for (matches) |match| {
            try stdout_writer.writeAll(match.slice);
            try stdout_writer.writeAll("\n");
        }
        try stdout_writer.flush();
    } else {
        if (re.find(input) catch |err| {
            try stderr_writer.print("error: match failed: {s}\n", .{@errorName(err)});
            try stderr_writer.flush();
            std.process.exit(1);
        }) |match| {
            var mut_match = match;
            defer mut_match.deinit(allocator);
            try stdout_writer.writeAll(match.slice);
            try stdout_writer.writeAll("\n");
            try stdout_writer.flush();
        } else {
            std.process.exit(1);
        }
    }
}
