const std = @import("std");
const RegexModule = @import("regex");
const Regex = RegexModule.Regex;
const MongoExternalOptions = RegexModule.common.MongoExternalOptions;
const c = @cImport({
    @cInclude("sqlite3ext.h");
});

const ARG_INDEX_JSON: usize = 0;
const ARG_INDEX_PATH: usize = 1;
const ARG_INDEX_PATTERN: usize = 2;
const ARG_INDEX_FLAGS: usize = 3;
const AUXDATA_INDEX_PATTERN: c_int = @intCast(ARG_INDEX_PATTERN);

const BsonRegexError = error{
    InvalidJson,
    InvalidPath,
    UnsupportedPath,
    InvalidFlags,
    InvalidPattern,
    Timeout,
    MatchError,
    OutOfMemory,
    Internal,
};

const BsonRegexRequest = struct {
    json_text: []const u8,
    path: []const u8,
    pattern: []const u8,
    flags: []const u8,
};

const PathPolicy = struct {
    require_root_dollar: bool = true,
    allow_array_index: bool = false,
    allow_numeric_object_keys: bool = true,
};

const RuntimeLimits = struct {
    /// Database-facing backtracking budget. `ExecutionSession.setMaxSteps()` is a no-op for the NFA engine.
    max_backtrack_steps: usize = 100_000,
};

const ArenaPolicy = struct {
    /// Retain row-local arena capacity up to this threshold before fully releasing it.
    max_row_arena_capacity: usize = 2 * 1024 * 1024,
};

const WrapperPolicy = struct {
    path: PathPolicy = .{},
    runtime: RuntimeLimits = .{},
    arena: ArenaPolicy = .{},
};

const PathSegment = union(enum) {
    field: []const u8,
    index: usize,
};

const RegexAuxData = struct {
    pattern: []u8,
    flags: []u8,
    regex: Regex,
};

const default_wrapper_policy = WrapperPolicy{};

var sqlite_api: ?*c.sqlite3_api_routines = null;
threadlocal var tl_arena: ?std.heap.ArenaAllocator = null;

fn destroyRegexAux(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |raw| {
        const entry: *RegexAuxData = @ptrCast(@alignCast(raw));
        entry.regex.deinit();
        std.heap.c_allocator.free(entry.pattern);
        std.heap.c_allocator.free(entry.flags);
        std.heap.c_allocator.destroy(entry);
    }
}

fn sqliteValueSlice(api: *c.sqlite3_api_routines, value: ?*c.sqlite3_value) ?[]const u8 {
    const text = api.value_text.?(value) orelse return null;
    const len = @as(usize, @intCast(api.value_bytes.?(value)));
    return text[0..len];
}

fn readRequest(api: *c.sqlite3_api_routines, args: []?*c.sqlite3_value) ?BsonRegexRequest {
    const json_text = sqliteValueSlice(api, args[ARG_INDEX_JSON]) orelse return null;
    const path = sqliteValueSlice(api, args[ARG_INDEX_PATH]) orelse return null;
    const pattern = sqliteValueSlice(api, args[ARG_INDEX_PATTERN]) orelse return null;
    const flags = sqliteValueSlice(api, args[ARG_INDEX_FLAGS]) orelse "";

    return .{
        .json_text = json_text,
        .path = path,
        .pattern = pattern,
        .flags = flags,
    };
}

fn validatePatternBytes(pattern: []const u8) BsonRegexError!void {
    if (std.mem.indexOfScalar(u8, pattern, 0) != null) return error.InvalidPattern;
}

fn validateFlagBytes(flags: []const u8) BsonRegexError!void {
    if (std.mem.indexOfScalar(u8, flags, 0) != null) return error.InvalidFlags;
}

fn getOrCompileRegex(context: ?*c.sqlite3_context, request: BsonRegexRequest) BsonRegexError!*const Regex {
    const api = sqlite_api orelse return error.Internal;
    const mongo_options = MongoExternalOptions.parse(request.flags) catch return error.InvalidFlags;
    const canonical_flags = mongo_options.canonicalSlice();

    if (api.get_auxdata.?(context, AUXDATA_INDEX_PATTERN)) |raw| {
        const cached: *RegexAuxData = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, cached.pattern, request.pattern) and std.mem.eql(u8, cached.flags, canonical_flags)) {
            return &cached.regex;
        }
    }

    var entry = std.heap.c_allocator.create(RegexAuxData) catch return error.OutOfMemory;
    errdefer std.heap.c_allocator.destroy(entry);

    entry.pattern = std.heap.c_allocator.dupe(u8, request.pattern) catch return error.OutOfMemory;
    errdefer std.heap.c_allocator.free(entry.pattern);

    entry.flags = std.heap.c_allocator.dupe(u8, canonical_flags) catch return error.OutOfMemory;
    errdefer std.heap.c_allocator.free(entry.flags);

    entry.regex = Regex.compileWithFlags(std.heap.c_allocator, request.pattern, mongo_options.compile_flags) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPattern,
    };

    api.set_auxdata.?(context, AUXDATA_INDEX_PATTERN, entry, destroyRegexAux);
    return &entry.regex;
}

fn getRowAllocator(policy: ArenaPolicy) std.mem.Allocator {
    if (tl_arena == null) {
        tl_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    } else if (tl_arena.?.queryCapacity() > policy.max_row_arena_capacity) {
        _ = tl_arena.?.reset(.free_all);
    } else {
        _ = tl_arena.?.reset(.retain_capacity);
    }

    return tl_arena.?.allocator();
}

fn createConfiguredSession(
    regex: *const Regex,
    allocator: std.mem.Allocator,
    limits: RuntimeLimits,
) BsonRegexError!RegexModule.ExecutionSession {
    var session = regex.session(allocator) catch return error.OutOfMemory;
    session.setMaxSteps(limits.max_backtrack_steps);
    return session;
}

fn runBsonRegexCore(
    allocator: std.mem.Allocator,
    regex: *const Regex,
    request: BsonRegexRequest,
    policy: WrapperPolicy,
) BsonRegexError!bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, request.json_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    const segments = try parsePath(allocator, request.path, policy.path);
    defer allocator.free(segments);

    const value_text = extractPathValue(parsed.value, segments, allocator) orelse return false;

    var session = try createConfiguredSession(regex, allocator, policy.runtime);
    defer session.deinit();

    return session.isMatch(value_text) catch return error.Timeout;
}

fn parsePath(allocator: std.mem.Allocator, path: []const u8, policy: PathPolicy) BsonRegexError![]PathSegment {
    if (path.len == 0) return error.InvalidPath;
    if (policy.require_root_dollar and path[0] != '$') return error.InvalidPath;

    var segments: std.ArrayList(PathSegment) = .empty;
    errdefer segments.deinit(allocator);

    var pos: usize = if (policy.require_root_dollar) 1 else 0;

    while (pos < path.len) {
        switch (path[pos]) {
            '.' => {
                pos += 1;
                if (pos >= path.len) return error.InvalidPath;
                if (path[pos] == '.') return error.InvalidPath;

                const start = pos;
                while (pos < path.len and path[pos] != '.' and path[pos] != '[' and path[pos] != ']') : (pos += 1) {}

                const field = path[start..pos];
                if (field.len == 0) return error.InvalidPath;
                if (!policy.allow_numeric_object_keys and isAsciiDigitString(field)) return error.UnsupportedPath;

                segments.append(allocator, .{ .field = field }) catch return error.OutOfMemory;

                while (pos < path.len and path[pos] == '[') {
                    try parseAndAppendIndex(allocator, path, &pos, policy, &segments);
                }
            },
            '[' => try parseAndAppendIndex(allocator, path, &pos, policy, &segments),
            else => return error.InvalidPath,
        }
    }

    return segments.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn parseAndAppendIndex(allocator: std.mem.Allocator, path: []const u8, pos: *usize, policy: PathPolicy, segments: *std.ArrayList(PathSegment)) BsonRegexError!void {
    if (!policy.allow_array_index) return error.UnsupportedPath;
    if (path[pos.*] != '[') return error.InvalidPath;

    pos.* += 1;
    const start = pos.*;
    while (pos.* < path.len and path[pos.*] >= '0' and path[pos.*] <= '9') : (pos.* += 1) {}
    if (start == pos.*) return error.InvalidPath;
    if (pos.* >= path.len or path[pos.*] != ']') return error.InvalidPath;

    const index = std.fmt.parseInt(usize, path[start..pos.*], 10) catch return error.InvalidPath;
    pos.* += 1;
    segments.append(allocator, .{ .index = index }) catch return error.OutOfMemory;
}

fn extractPathValue(value: std.json.Value, segments: []const PathSegment, allocator: std.mem.Allocator) ?[]const u8 {
    var current = value;

    for (segments) |segment| {
        switch (segment) {
            .field => |field| {
                current = switch (current) {
                    .object => |obj| obj.get(field) orelse return null,
                    else => return null,
                };
            },
            .index => |index| {
                current = switch (current) {
                    .array => |arr| if (index < arr.items.len) arr.items[index] else return null,
                    else => return null,
                };
            },
        }
    }

    return scalarValueToText(current, allocator);
}

fn scalarValueToText(value: std.json.Value, allocator: std.mem.Allocator) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        .number_string => |s| s,
        .bool => |b| if (b) "true" else "false",
        .integer => |i| std.fmt.allocPrint(allocator, "{}", .{i}) catch null,
        .float => |f| std.fmt.allocPrint(allocator, "{}", .{f}) catch null,
        else => null,
    };
}

fn isAsciiDigitString(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn mapCoreErrorToSqlite(context: ?*c.sqlite3_context, err: BsonRegexError) void {
    const api = sqlite_api orelse return;

    switch (err) {
        error.InvalidPath, error.UnsupportedPath => api.result_int.?(context, 0),
        error.InvalidJson => api.result_error.?(context, "Invalid JSON input", -1),
        error.InvalidFlags => api.result_error.?(context, "Invalid regex flags", -1),
        error.InvalidPattern => api.result_error.?(context, "Invalid regex pattern", -1),
        error.Timeout => api.result_error.?(context, "Regex execution timed out", -1),
        error.OutOfMemory => api.result_error_nomem.?(context),
        error.MatchError, error.Internal => api.result_error.?(context, "Match error", -1),
    }
}

fn bsonRegexFunc(
    context: ?*c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) callconv(.c) void {
    _ = argc;
    const api = sqlite_api orelse return;

    const args = argv[0..4];
    const request = readRequest(api, args) orelse {
        api.result_int.?(context, 0);
        return;
    };

    validatePatternBytes(request.pattern) catch |err| {
        mapCoreErrorToSqlite(context, err);
        return;
    };
    validateFlagBytes(request.flags) catch |err| {
        mapCoreErrorToSqlite(context, err);
        return;
    };

    const regex = getOrCompileRegex(context, request) catch |err| {
        mapCoreErrorToSqlite(context, err);
        return;
    };

    const result = runBsonRegexCore(getRowAllocator(default_wrapper_policy.arena), regex, request, default_wrapper_policy) catch |err| {
        mapCoreErrorToSqlite(context, err);
        return;
    };

    api.result_int.?(context, if (result) 1 else 0);
}

export fn sqlite3_puresqlite_helpers_init(
    db: ?*c.sqlite3,
    pz_err_msg: ?*[*:0]const u8,
    p_api: ?*c.sqlite3_api_routines,
) c_int {
    _ = pz_err_msg;
    sqlite_api = p_api orelse return c.SQLITE_ERROR;

    return sqlite_api.?.create_function_v2.?(
        db,
        "bson_regex",
        4,
        c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC,
        null,
        bsonRegexFunc,
        null,
        null,
        null,
    );
}
