const std = @import("std");

// Hardcoded URLs for Unicode 15.1.0 (no comptime issues)
const UNICODE_DATA_URL = "https://www.unicode.org/Public/15.1.0/ucd/UnicodeData.txt";
const SCRIPTS_URL = "https://www.unicode.org/Public/15.1.0/ucd/Scripts.txt";
const GRAPHEME_BREAK_URL = "https://www.unicode.org/Public/15.1.0/ucd/auxiliary/GraphemeBreakProperty.txt";

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

/// Grapheme Break Property values (matching PCRE2 + Unicode UAX#29)
const GraphemeBreakProperty = enum(u8) {
    gbOther = 0,
    gbCR = 1,
    gbLF = 2,
    gbControl = 3,
    gbExtend = 4,
    gbZWJ = 5,
    gbRegional_Indicator = 6,
    gbPrepend = 7,
    gbSpacingMark = 8,
    gbL = 9,
    gbV = 10,
    gbT = 11,
    gbLV = 12,
    gbLVT = 13,
    gbExtended_Pictographic = 14, // PCRE2 extension for emoji ZWJ rules
};

const UcdRecord = struct {
    codepoint: u21,
    category: GeneralCategory,
    script: u8,
    grapheme: GraphemeBreakProperty,
    lowercase_delta: i32,
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

    const grapheme_data = try downloadOrCache(allocator, "GraphemeBreakProperty.txt", GRAPHEME_BREAK_URL, cache_dir);
    defer allocator.free(grapheme_data);

    std.debug.print("Downloaded {d} bytes of UnicodeData.txt\n", .{unicode_data.len});
    std.debug.print("Downloaded {d} bytes of Scripts.txt\n", .{scripts_data.len});
    std.debug.print("Downloaded {d} bytes of GraphemeBreakProperty.txt\n", .{grapheme_data.len});

    // Parse UnicodeData.txt
    var records = try std.ArrayList(UcdRecord).initCapacity(allocator, 0);
    defer records.deinit(allocator);

    try parseUnicodeData(allocator, unicode_data, &records);
    std.debug.print("Parsed {d} Unicode records\n", .{records.items.len});

    // Allocate array for true codepoint -> grapheme property mapping
    const graphemes = try allocator.alloc(GraphemeBreakProperty, 0x110000);
    defer allocator.free(graphemes);
    @memset(graphemes, .gbOther);

    // Parse GraphemeBreakProperty.txt and update records
    parseGraphemeBreakProperty(grapheme_data, records.items, graphemes);
    std.debug.print("Applied grapheme break properties\n", .{});

    // Build two-stage lookup tables
    const tables = try buildLookupTables(allocator, records.items, graphemes);
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

        var field_idx: usize = 1;
        var category: GeneralCategory = .Cn;
        var lowercase_mapping: u21 = codepoint;

        while (fields.next()) |field| : (field_idx += 1) {
            if (field_idx == 2) {
                category = parseCategoryString(field) orelse .Cn;
            } else if (field_idx == 13) {
                // Field 13 is Simple_Lowercase_Mapping
                if (field.len > 0) {
                    lowercase_mapping = std.fmt.parseInt(u21, field, 16) catch codepoint;
                }
            }
        }

        const delta: i32 = @as(i32, @intCast(lowercase_mapping)) - @as(i32, @intCast(codepoint));

        try records.append(allocator, .{
            .codepoint = codepoint,
            .category = category,
            .script = 0, // Will be filled from Scripts.txt
            .grapheme = .gbOther, // Will be filled from GraphemeBreakProperty.txt
            .lowercase_delta = delta,
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

fn parseGraphemePropertyString(s: []const u8) GraphemeBreakProperty {
    const map = std.StaticStringMap(GraphemeBreakProperty).initComptime(.{
        .{ "CR", .gbCR },
        .{ "LF", .gbLF },
        .{ "Control", .gbControl },
        .{ "Extend", .gbExtend },
        .{ "ZWJ", .gbZWJ },
        .{ "Regional_Indicator", .gbRegional_Indicator },
        .{ "Prepend", .gbPrepend },
        .{ "SpacingMark", .gbSpacingMark },
        .{ "L", .gbL },
        .{ "V", .gbV },
        .{ "T", .gbT },
        .{ "LV", .gbLV },
        .{ "LVT", .gbLVT },
        // Extended Pictographic - PCRE2 extension for emoji ZWJ sequences
        .{ "Extended_Pictographic", .gbExtended_Pictographic },
    });
    return map.get(s) orelse .gbOther;
}

/// Parse GraphemeBreakProperty.txt and update records in-place
fn parseGraphemeBreakProperty(data: []const u8, records: []const UcdRecord, graphemes: []GraphemeBreakProperty) void {
    // First, set default grapheme properties based on category
    for (records) |record| {
        if (record.codepoint >= graphemes.len) continue;
        const cat = record.category;
        graphemes[record.codepoint] = switch (cat) {
            .Cc, .Cf => .gbControl,
            .Mn => .gbExtend,
            .Mc => .gbSpacingMark,
            else => .gbOther,
        };
    }

    // Mark Extended Pictographic (emoji ranges that participate in ZWJ sequences)
    // These ranges are from Unicode's Extended_Pictographic property
    const emoji_ranges = [_]struct { start: u21, end: u21 }{
        .{ .start = 0x2600, .end = 0x26FF }, // Miscellaneous Symbols
        .{ .start = 0x2700, .end = 0x27BF }, // Dingbats
        .{ .start = 0x1F300, .end = 0x1F5FF }, // Misc Symbols and Pictographs
        .{ .start = 0x1F600, .end = 0x1F64F }, // Emoticons
        .{ .start = 0x1F680, .end = 0x1F6FF }, // Transport and Map
        .{ .start = 0x1F1E6, .end = 0x1F1FF }, // Regional Indicator (flags)
        .{ .start = 0x1F900, .end = 0x1F9FF }, // Additional Emoticons
        .{ .start = 0x1FA00, .end = 0x1FA6F }, // Chess Symbols
        .{ .start = 0x1FA70, .end = 0x1FAFF }, // Symbols and Pictographs Extended-A
        .{ .start = 0x1F780, .end = 0x1F7FF }, // Geometric Shapes Extended
        .{ .start = 0x1F180, .end = 0x1F1FF }, // Arrows Extended-B
    };

    for (emoji_ranges) |range| {
        for (range.start..range.end + 1) |cp| {
            if (cp < graphemes.len) {
                graphemes[cp] = .gbExtended_Pictographic;
            }
        }
    }

    // Parse the GraphemeBreakProperty.txt
    // Format: CODEPOINT..CODEPOINT;PROPERTY
    // or: CODEPOINT;PROPERTY
    var lines = std.mem.splitScalar(u8, data, '\n');

    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        // Skip lines without ;
        if (std.mem.indexOfScalar(u8, line, ';') == null) continue;

        var fields = std.mem.splitScalar(u8, line, ';');
        const range_str_raw = fields.next() orelse continue;
        const property_str_raw = fields.next() orelse continue;

        // Strip inline comments and trim whitespace
        const hash_idx = std.mem.indexOfScalar(u8, property_str_raw, '#') orelse property_str_raw.len;
        const property_str = std.mem.trim(u8, property_str_raw[0..hash_idx], &std.ascii.whitespace);
        const range_str = std.mem.trim(u8, range_str_raw, &std.ascii.whitespace);

        const property = parseGraphemePropertyString(property_str);

        // Parse range (could be "0000..001F" or "0000")
        var range_start: u21 = 0;
        var range_end: u21 = 0;

        if (std.mem.indexOfScalar(u8, range_str, '.')) |dot_idx| {
            // Range like "0000..001F"
            range_start = std.fmt.parseInt(u21, range_str[0..dot_idx], 16) catch 0;
            range_end = std.fmt.parseInt(u21, range_str[dot_idx + 2 ..], 16) catch 0;
        } else {
            // Single codepoint
            range_start = std.fmt.parseInt(u21, range_str, 16) catch continue;
            range_end = range_start;
        }

        // Update records in range (with safety checks)
        if (range_start <= range_end and range_start < graphemes.len) {
            const end_idx = @min(range_end + 1, graphemes.len);
            for (range_start..end_idx) |cp| {
                graphemes[cp] = property;
            }
        }
    }
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
    try testing.expectEqual(@as(i32, 0x20), records.items[0].lowercase_delta); // A -> a
    try testing.expectEqual(@as(u21, 0x0061), records.items[1].codepoint);
    try testing.expectEqual(GeneralCategory.Ll, records.items[1].category);
    try testing.expectEqual(@as(i32, 0), records.items[1].lowercase_delta); // a -> a
}

fn buildLookupTables(allocator: std.mem.Allocator, records: []const UcdRecord, graphemes: []const GraphemeBreakProperty) !LookupTables {
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
    try unique_records.append(allocator, .{ .codepoint = 0, .category = .Cn, .script = 0, .grapheme = .gbOther, .lowercase_delta = 0 });

    // Map each codepoint to a record index
    for (records) |base_record| {
        var record = base_record;
        if (record.codepoint < MAX_CODEPOINT) {
            record.grapheme = graphemes[record.codepoint];
        }

        // Find or add record
        var record_idx: u16 = 0;
        for (unique_records.items, 0..) |existing, idx| {
            if (existing.category == record.category and
                existing.script == record.script and
                existing.grapheme == record.grapheme and
                existing.lowercase_delta == record.lowercase_delta)
            {
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

    // Write GraphemeBreakProperty enum
    try content.appendSlice(allocator, "/// Grapheme Break Property for \\X support (Unicode UAX#29 + PCRE2 extension)\n");
    try content.appendSlice(allocator, "pub const GraphemeBreakProperty = enum(u8) {\n");
    try content.appendSlice(allocator, "    gbOther = 0,\n");
    try content.appendSlice(allocator, "    gbCR = 1,\n");
    try content.appendSlice(allocator, "    gbLF = 2,\n");
    try content.appendSlice(allocator, "    gbControl = 3,\n");
    try content.appendSlice(allocator, "    gbExtend = 4,\n");
    try content.appendSlice(allocator, "    gbZWJ = 5,\n");
    try content.appendSlice(allocator, "    gbRegional_Indicator = 6,\n");
    try content.appendSlice(allocator, "    gbPrepend = 7,\n");
    try content.appendSlice(allocator, "    gbSpacingMark = 8,\n");
    try content.appendSlice(allocator, "    gbL = 9,\n");
    try content.appendSlice(allocator, "    gbV = 10,\n");
    try content.appendSlice(allocator, "    gbT = 11,\n");
    try content.appendSlice(allocator, "    gbLV = 12,\n");
    try content.appendSlice(allocator, "    gbLVT = 13,\n");
    try content.appendSlice(allocator, "    gbExtended_Pictographic = 14,\n");
    try content.appendSlice(allocator, "};\n\n");

    // Write UcdRecord struct (without codepoint - we use staged tables for lookup)
    try content.appendSlice(allocator, "pub const UcdRecord = packed struct {\n");
    try content.appendSlice(allocator, "    category: u8,\n");
    try content.appendSlice(allocator, "    script: u8,\n");
    try content.appendSlice(allocator, "    grapheme: u8,\n");
    try content.appendSlice(allocator, "    lowercase_delta: i32,\n");
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
        const record_str = try std.fmt.allocPrint(allocator, "    .{{ .category = {d}, .script = {d}, .grapheme = {d}, .lowercase_delta = {d} }},\n", .{
            @intFromEnum(record.category),
            record.script,
            @intFromEnum(record.grapheme),
            record.lowercase_delta,
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
        \\pub fn isDigit(codepoint: u21, use_unicode: bool) bool {
        \\    if (codepoint < 128) {
        \\        return codepoint >= '0' and codepoint <= '9';
        \\    }
        \\    if (!use_unicode) return false;
        \\    const rec = getUcdRecord(codepoint);
        \\    return rec.category == 8; // Nd = Decimal Digit
        \\}
        \\
        \\pub fn isWhitespace(codepoint: u21, use_unicode: bool) bool {
        \\    if (codepoint < 128) {
        \\        return switch (@as(u8, @intCast(codepoint))) {
        \\            ' ', 9, 10, 13, 11, 12 => true,
        \\            else => false,
        \\        };
        \\    }
        \\    if (!use_unicode) return false;
        \\    const rec = getUcdRecord(codepoint);
        \\    const cat = rec.category;
        \\    return cat >= 22 and cat <= 24; // Zs, Zl, Zp = Separator categories
        \\}
        \\
        \\/// Get Grapheme Break Property for \\X support
        \\pub fn UCD_GRAPHBREAK(codepoint: u21) GraphemeBreakProperty {
        \\    if (codepoint >= 0x110000) return .gbOther;
        \\    const rec = getUcdRecord(codepoint);
        \\    return @as(GraphemeBreakProperty, @enumFromInt(rec.grapheme));
        \\}
        \\
    );

    // Write to file
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content.items });
}
