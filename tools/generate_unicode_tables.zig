const std = @import("std");

// Hardcoded URLs for Unicode 15.1.0 (no comptime issues)
const UNICODE_DATA_URL = "https://www.unicode.org/Public/15.1.0/ucd/UnicodeData.txt";
const SCRIPTS_URL = "https://www.unicode.org/Public/15.1.0/ucd/Scripts.txt";

const GeneralCategory = enum(u8) {
    Lu = 0, // Letter, uppercase
    Ll = 1, // Letter, lowercase
    Lt = 2, // Letter, titlecase
    Lm = 3, // Letter, modifier
    Lo = 4, // Letter, other
    Mn = 5, // Mark, nonspacing
    Mc = 6, // Mark, spacing combining
    Me = 7, // Mark, enclosing
    Nd = 8, // Number, decimal digit
    Nl = 9, // Number, letter
    No = 10, // Number, other
    Pc = 11, // Punctuation, connector
    Pd = 12, // Punctuation, dash
    Ps = 13, // Punctuation, open
    Pe = 14, // Punctuation, close
    Pi = 15, // Punctuation, initial quote
    Pf = 16, // Punctuation, final quote
    Po = 17, // Punctuation, other
    Sm = 18, // Symbol, math
    Sc = 19, // Symbol, currency
    Sk = 20, // Symbol, modifier
    So = 21, // Symbol, other
    Zs = 22, // Separator, space
    Zl = 23, // Separator, line
    Zp = 24, // Separator, paragraph
    Cc = 25, // Other, control
    Cf = 26, // Other, format
    Cs = 27, // Other, surrogate
    Co = 28, // Other, private use
    Cn = 29, // Other, not assigned
};

const UcdRecord = struct {
    codepoint: u21,
    category: GeneralCategory,
    script: u8,
};

const LookupTables = struct {
    stage1: []u16,
    stage2: []u16,
    records: []UcdRecord,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Generating Unicode 15.1.0 tables...\n", .{});

    // Create cache directory
    const cache_dir = "tools/unicode_data";
    std.fs.cwd().makeDir(cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Download Unicode data files
    const unicode_data = try downloadOrCache(allocator, "UnicodeData.txt", UNICODE_DATA_URL, cache_dir);
    defer allocator.free(unicode_data);

    const scripts_data = try downloadOrCache(allocator, "Scripts.txt", SCRIPTS_URL, cache_dir);
    defer allocator.free(scripts_data);

    std.debug.print("Downloaded {d} bytes of UnicodeData.txt\n", .{unicode_data.len});
    std.debug.print("Downloaded {d} bytes of Scripts.txt\n", .{scripts_data.len});

    // Parse UnicodeData.txt
    var records = try std.ArrayList(UcdRecord).initCapacity(allocator, 0);
    defer records.deinit(allocator);

    try parseUnicodeData(allocator, unicode_data, &records);
    std.debug.print("Parsed {d} Unicode records\n", .{records.items.len});

    // Build two-stage lookup tables
    const tables = try buildLookupTables(allocator, records.items);
    defer {
        allocator.free(tables.stage1);
        allocator.free(tables.stage2);
        allocator.free(tables.records);
    }
    std.debug.print("Built lookup tables: stage1={d}, stage2={d}, records={d}\n", .{
        tables.stage1.len,
        tables.stage2.len,
        tables.records.len,
    });

    // Generate src/unicode_tables.zig
    try generateTablesFile(allocator, tables, "src/unicode_tables.zig");
    std.debug.print("Generated src/unicode_tables.zig\n", .{});

    std.debug.print("Done!\n", .{});
}

fn downloadOrCache(allocator: std.mem.Allocator, filename: []const u8, url: []const u8, cache_dir: []const u8) ![]u8 {
    const cache_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir, filename });
    defer allocator.free(cache_path);

    // Try to read from cache first
    if (std.fs.cwd().readFileAlloc(allocator, cache_path, 10 * 1024 * 1024)) |cached| {
        std.debug.print("Using cached {s}\n", .{filename});
        return cached;
    } else |_| {
        std.debug.print("Downloading {s}...\n", .{filename});
    }

    // Download using curl
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "curl", "-fsSL", url, "-o", cache_path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("curl failed: {s}\n", .{result.stderr});
        return error.DownloadFailed;
    }

    // Read the downloaded file
    return try std.fs.cwd().readFileAlloc(allocator, cache_path, 10 * 1024 * 1024);
}

fn parseUnicodeData(allocator: std.mem.Allocator, data: []const u8, records: *std.ArrayList(UcdRecord)) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Format: CODEPOINT;NAME;CATEGORY;...
        var fields = std.mem.splitScalar(u8, line, ';');

        const codepoint_str = fields.next() orelse continue;
        const codepoint = try std.fmt.parseInt(u21, codepoint_str, 16);

        _ = fields.next(); // Skip name

        const category_str = fields.next() orelse continue;
        const category = parseCategoryString(category_str) orelse .Cn;

        try records.append(allocator, .{
            .codepoint = codepoint,
            .category = category,
            .script = 0, // Will be filled from Scripts.txt
        });
    }
}

fn parseCategoryString(s: []const u8) ?GeneralCategory {
    const map = std.StaticStringMap(GeneralCategory).initComptime(.{
        .{ "Lu", .Lu }, .{ "Ll", .Ll }, .{ "Lt", .Lt }, .{ "Lm", .Lm }, .{ "Lo", .Lo },
        .{ "Mn", .Mn }, .{ "Mc", .Mc }, .{ "Me", .Me }, .{ "Nd", .Nd }, .{ "Nl", .Nl },
        .{ "No", .No }, .{ "Pc", .Pc }, .{ "Pd", .Pd }, .{ "Ps", .Ps }, .{ "Pe", .Pe },
        .{ "Pi", .Pi }, .{ "Pf", .Pf }, .{ "Po", .Po }, .{ "Sm", .Sm }, .{ "Sc", .Sc },
        .{ "Sk", .Sk }, .{ "So", .So }, .{ "Zs", .Zs }, .{ "Zl", .Zl }, .{ "Zp", .Zp },
        .{ "Cc", .Cc }, .{ "Cf", .Cf }, .{ "Cs", .Cs }, .{ "Co", .Co }, .{ "Cn", .Cn },
    });
    return map.get(s);
}

// Tests
test "parseCategoryString" {
    const testing = std.testing;
    try testing.expectEqual(GeneralCategory.Lu, parseCategoryString("Lu").?);
    try testing.expectEqual(GeneralCategory.Nd, parseCategoryString("Nd").?);
    try testing.expectEqual(GeneralCategory.Pc, parseCategoryString("Pc").?);
    try testing.expect(parseCategoryString("XX") == null);
}

test "parseUnicodeData basic" {
    const testing = std.testing;
    const data = "0041;LATIN CAPITAL LETTER A;Lu;0;L;;;;;N;;;;0061;\n0061;LATIN SMALL LETTER A;Ll;0;L;;;;;N;;;0041;;0041\n";

    var records = try std.ArrayList(UcdRecord).initCapacity(testing.allocator, 0);
    defer records.deinit(testing.allocator);

    try parseUnicodeData(testing.allocator, data, &records);

    try testing.expectEqual(@as(usize, 2), records.items.len);
    try testing.expectEqual(@as(u21, 0x0041), records.items[0].codepoint);
    try testing.expectEqual(GeneralCategory.Lu, records.items[0].category);
    try testing.expectEqual(@as(u21, 0x0061), records.items[1].codepoint);
    try testing.expectEqual(GeneralCategory.Ll, records.items[1].category);
}

fn buildLookupTables(allocator: std.mem.Allocator, records: []const UcdRecord) !LookupTables {
    const BLOCK_SIZE = 128;
    const MAX_CODEPOINT = 0x110000;
    const NUM_BLOCKS = (MAX_CODEPOINT + BLOCK_SIZE - 1) / BLOCK_SIZE;

    // Create full codepoint array (sparse)
    var codepoint_to_record = try allocator.alloc(u16, MAX_CODEPOINT);
    defer allocator.free(codepoint_to_record);
    @memset(codepoint_to_record, 0); // Default to record 0 (Cn - not assigned)

    // Build unique records list
    var unique_records = try std.ArrayList(UcdRecord).initCapacity(allocator, 0);
    defer unique_records.deinit(allocator);

    // Add default record (Cn)
    try unique_records.append(allocator, .{ .codepoint = 0, .category = .Cn, .script = 0 });

    // Map each codepoint to a record index
    for (records) |record| {
        // Find or add record
        var record_idx: u16 = 0;
        for (unique_records.items, 0..) |existing, idx| {
            if (existing.category == record.category and existing.script == record.script) {
                record_idx = @intCast(idx);
                break;
            }
        } else {
            record_idx = @intCast(unique_records.items.len);
            try unique_records.append(allocator, record);
        }

        if (record.codepoint < MAX_CODEPOINT) {
            codepoint_to_record[record.codepoint] = record_idx;
        }
    }

    // Build stage2 blocks
    var blocks = try std.ArrayList([BLOCK_SIZE]u16).initCapacity(allocator, 0);
    defer blocks.deinit(allocator);

    var stage1 = try allocator.alloc(u16, NUM_BLOCKS);

    for (0..NUM_BLOCKS) |block_idx| {
        var block: [BLOCK_SIZE]u16 = undefined;
        const base = block_idx * BLOCK_SIZE;

        for (0..BLOCK_SIZE) |i| {
            const cp = base + i;
            block[i] = if (cp < MAX_CODEPOINT) codepoint_to_record[cp] else 0;
        }

        // Find or add block
        var found_idx: ?usize = null;
        for (blocks.items, 0..) |existing, idx| {
            if (std.mem.eql(u16, &existing, &block)) {
                found_idx = idx;
                break;
            }
        }

        if (found_idx) |idx| {
            stage1[block_idx] = @intCast(idx);
        } else {
            stage1[block_idx] = @intCast(blocks.items.len);
            try blocks.append(allocator, block);
        }
    }

    // Flatten stage2
    var stage2 = try allocator.alloc(u16, blocks.items.len * BLOCK_SIZE);
    for (blocks.items, 0..) |block, i| {
        @memcpy(stage2[i * BLOCK_SIZE .. (i + 1) * BLOCK_SIZE], &block);
    }

    return .{
        .stage1 = stage1,
        .stage2 = stage2,
        .records = try allocator.dupe(UcdRecord, unique_records.items),
    };
}

fn generateTablesFile(allocator: std.mem.Allocator, tables: LookupTables, path: []const u8) !void {
    var content = try std.ArrayList(u8).initCapacity(allocator, 1024 * 1024);
    defer content.deinit(allocator);

    // Build file content as string
    try content.appendSlice(allocator, "// Auto-generated Unicode lookup tables\n");
    try content.appendSlice(allocator, "// DO NOT EDIT - regenerate with tools/generate_unicode_tables.zig\n\n");
    try content.appendSlice(allocator, "const std = @import(\"std\");\n\n");

    // Write GeneralCategory enum
    try content.appendSlice(allocator, "pub const GeneralCategory = enum(u8) {\n");
    try content.appendSlice(allocator, "    Lu = 0, Ll = 1, Lt = 2, Lm = 3, Lo = 4,\n");
    try content.appendSlice(allocator, "    Mn = 5, Mc = 6, Me = 7,\n");
    try content.appendSlice(allocator, "    Nd = 8, Nl = 9, No = 10,\n");
    try content.appendSlice(allocator, "    Pc = 11, Pd = 12, Ps = 13, Pe = 14, Pi = 15, Pf = 16, Po = 17,\n");
    try content.appendSlice(allocator, "    Sm = 18, Sc = 19, Sk = 20, So = 21,\n");
    try content.appendSlice(allocator, "    Zs = 22, Zl = 23, Zp = 24,\n");
    try content.appendSlice(allocator, "    Cc = 25, Cf = 26, Cs = 27, Co = 28, Cn = 29,\n");
    try content.appendSlice(allocator, "};\n\n");

    // Write UcdRecord struct
    try content.appendSlice(allocator, "pub const UcdRecord = packed struct {\n");
    try content.appendSlice(allocator, "    category: u8,\n");
    try content.appendSlice(allocator, "    script: u8,\n");
    try content.appendSlice(allocator, "};\n\n");

    // Write stage1
    try content.appendSlice(allocator, "pub const UCD_STAGE1 = [_]u16{\n");
    for (tables.stage1, 0..) |val, i| {
        if (i % 16 == 0) try content.appendSlice(allocator, "    ");
        const num_str = try std.fmt.allocPrint(allocator, "{d},", .{val});
        defer allocator.free(num_str);
        try content.appendSlice(allocator, num_str);
        if (i % 16 == 15) try content.appendSlice(allocator, "\n");
    }
    try content.appendSlice(allocator, "};\n\n");

    // Write stage2
    try content.appendSlice(allocator, "pub const UCD_STAGE2 = [_]u16{\n");
    for (tables.stage2, 0..) |val, i| {
        if (i % 16 == 0) try content.appendSlice(allocator, "    ");
        const num_str = try std.fmt.allocPrint(allocator, "{d},", .{val});
        defer allocator.free(num_str);
        try content.appendSlice(allocator, num_str);
        if (i % 16 == 15) try content.appendSlice(allocator, "\n");
    }
    try content.appendSlice(allocator, "};\n\n");

    // Write records
    try content.appendSlice(allocator, "pub const UCD_RECORDS = [_]UcdRecord{\n");
    for (tables.records) |record| {
        const record_str = try std.fmt.allocPrint(allocator, "    .{{ .category = {d}, .script = {d} }},\n", .{
            @intFromEnum(record.category),
            record.script,
        });
        defer allocator.free(record_str);
        try content.appendSlice(allocator, record_str);
    }
    try content.appendSlice(allocator, "};\n\n");

    // Write helper functions
    try content.appendSlice(allocator,
        \\pub fn getUcdRecord(codepoint: u21) UcdRecord {
        \\    if (codepoint >= 0x110000) return UCD_RECORDS[0];
        \\    const stage1_idx = codepoint >> 7;
        \\    const stage2_idx = UCD_STAGE1[stage1_idx] * 128 + (codepoint & 0x7F);
        \\    const record_idx = UCD_STAGE2[stage2_idx];
        \\    return UCD_RECORDS[record_idx];
        \\}
        \\
        \\pub fn isWordChar(codepoint: u21, use_unicode: bool) bool {
        \\    if (codepoint < 128) {
        \\        return switch (@as(u8, @intCast(codepoint))) {
        \\            'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        \\            else => false,
        \\        };
        \\    }
        \\    if (!use_unicode) return false;
        \\    const rec = getUcdRecord(codepoint);
        \\    const cat = rec.category;
        \\    return (cat >= 0 and cat <= 4) or (cat >= 8 and cat <= 10) or cat == 5 or cat == 11;
        \\}
        \\
    );

    // Write to file
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content.items });
}
