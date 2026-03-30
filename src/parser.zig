const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const RegexError = @import("errors.zig").RegexError;
const ErrorContext = @import("errors.zig").ErrorContext;

/// Token types for lexical analysis
pub const TokenType = enum {
    literal,
    escaped_literal,
    dot,
    star,
    plus,
    question,
    pipe,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    caret,
    dollar,
    backslash,
    escape_char,
    escape_d,
    escape_D,
    escape_w,
    escape_W,
    escape_s,
    escape_S,
    escape_h,
    escape_H,
    escape_v,
    escape_V,
    escape_R,
    escape_X,
    escape_b,
    escape_B,
    escape_A,
    escape_z,
    escape_Z,
    escape_p,
    escape_P,
    escape_g,
    escape_k,
    backref,
    pcre_ucp,
    pcre_utf,
    pcre_ignore,
    eof,
};

pub const Token = struct {
    token_type: TokenType,
    value: u8 = 0,
    span: common.Span,
};

/// Lexer for tokenizing regex patterns
pub const Lexer = struct {
    input: []const u8,
    pos: usize,
    start_pos: usize,
    flags: common.CompileFlags,
    literal_mode: bool = false,
    extended_trivia_enabled: bool = true,

    pub fn init(input: []const u8, flags: common.CompileFlags) Lexer {
        return .{
            .input = input,
            .pos = 0,
            .start_pos = 0,
            .flags = flags,
        };
    }

    fn peek(self: *Lexer) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn advance(self: *Lexer) ?u8 {
        if (self.pos >= self.input.len) return null;
        const c = self.input[self.pos];
        self.pos += 1;

        // Skip UTF-8 continuation bytes (10xxxxxx) to keep tokens aligned with codepoints
        // This ensures that multi-byte UTF-8 characters are treated as single tokens
        if (c >= 0x80) {
            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            // Skip the continuation bytes (we already advanced by 1, so skip len-1 more)
            var i: usize = 1;
            while (i < len and self.pos < self.input.len) : (i += 1) {
                self.pos += 1;
            }
        }

        return c;
    }

    fn makeToken(self: *Lexer, token_type: TokenType, value: u8) Token {
        return .{
            .token_type = token_type,
            .value = value,
            .span = common.Span.init(self.start_pos, self.pos),
        };
    }

    fn makeTokenWithSpan(self: *Lexer, token_type: TokenType, value: u8, start: usize, end: usize) Token {
        _ = self;
        return .{
            .token_type = token_type,
            .value = value,
            .span = common.Span.init(start, end),
        };
    }

    fn codepointStartForCurrentPos(self: *Lexer, leading_byte: u8) usize {
        if (leading_byte < 0x80) return self.pos - 1;
        const len = std.unicode.utf8ByteSequenceLength(leading_byte) catch 1;
        return self.pos - len;
    }

    fn tokenForConsumedCharWithSpan(self: *Lexer, c: u8, start: usize, end: usize) Token {
        return switch (c) {
            '.' => self.makeTokenWithSpan(.dot, c, start, end),
            '*' => self.makeTokenWithSpan(.star, c, start, end),
            '+' => self.makeTokenWithSpan(.plus, c, start, end),
            '?' => self.makeTokenWithSpan(.question, c, start, end),
            '|' => self.makeTokenWithSpan(.pipe, c, start, end),
            '(' => self.makeTokenWithSpan(.lparen, c, start, end),
            ')' => self.makeTokenWithSpan(.rparen, c, start, end),
            '[' => self.makeTokenWithSpan(.lbracket, c, start, end),
            ']' => self.makeTokenWithSpan(.rbracket, c, start, end),
            '{' => self.makeTokenWithSpan(.lbrace, c, start, end),
            '}' => self.makeTokenWithSpan(.rbrace, c, start, end),
            '^' => self.makeTokenWithSpan(.caret, c, start, end),
            '$' => self.makeTokenWithSpan(.dollar, c, start, end),
            else => self.makeTokenWithSpan(.literal, c, start, end),
        };
    }

    fn tokenForCurrentCodepoint(self: *Lexer, c: u8) Token {
        const start = self.codepointStartForCurrentPos(c);
        return self.tokenForConsumedCharWithSpan(c, start, self.pos);
    }

    fn literalTokenForCurrentCodepoint(self: *Lexer, c: u8) Token {
        const start = self.codepointStartForCurrentPos(c);
        return self.makeTokenWithSpan(.literal, c, start, self.pos);
    }

    fn skipExtendedTrivia(self: *Lexer) void {
        if (!self.flags.extended or !self.extended_trivia_enabled or self.literal_mode) return;

        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                _ = self.advance();
                continue;
            }

            if (c == '#') {
                _ = self.advance();
                while (self.peek()) |comment_char| {
                    if (comment_char == '\n' or comment_char == '\r') break;
                    _ = self.advance();
                }
                continue;
            }

            break;
        }
    }

    fn parseEscape(self: *Lexer) RegexError!Token {
        // We've already consumed the backslash
        const c = self.advance() orelse return RegexError.UnexpectedEndOfPattern;

        return switch (c) {
            'd' => self.makeToken(.escape_d, 0),
            'D' => self.makeToken(.escape_D, 0),
            'w' => self.makeToken(.escape_w, 0),
            'W' => self.makeToken(.escape_W, 0),
            's' => self.makeToken(.escape_s, 0),
            'S' => self.makeToken(.escape_S, 0),
            'h' => self.makeToken(.escape_h, 0),
            'H' => self.makeToken(.escape_H, 0),
            'v' => self.makeToken(.escape_v, 0),
            'V' => self.makeToken(.escape_V, 0),
            'R' => self.makeToken(.escape_R, 0),
            'X' => self.makeToken(.escape_X, 0),
            'b' => self.makeToken(.escape_b, 0),
            'B' => self.makeToken(.escape_B, 0),
            'A' => self.makeToken(.escape_A, 0),
            'z' => self.makeToken(.escape_z, 0),
            'Z' => self.makeToken(.escape_Z, 0),
            'n' => self.makeToken(.escape_char, '\n'),
            't' => self.makeToken(.escape_char, '\t'),
            'r' => self.makeToken(.escape_char, '\r'),
            'x' => {
                // Parse \xNN hex escape
                const hex1 = self.advance() orelse return RegexError.UnexpectedEndOfPattern;
                const hex2 = self.advance() orelse return RegexError.UnexpectedEndOfPattern;

                if (!std.ascii.isHex(hex1) or !std.ascii.isHex(hex2)) {
                    return RegexError.InvalidEscapeSequence;
                }

                const hex_str = [_]u8{ hex1, hex2 };
                const value = std.fmt.parseInt(u8, &hex_str, 16) catch return RegexError.InvalidEscapeSequence;

                // BSON/MongoDB compatibility: regex patterns cannot contain null bytes
                if (value == 0) {
                    return RegexError.InvalidPattern;
                }

                return self.makeToken(.escape_char, value);
            },
            'p', 'P' => {
                // Unicode properties: \p{Latin}, \p{Greek}, etc.
                // Parser will handle the {Name} part
                return self.makeToken(if (c == 'P') .escape_P else .escape_p, 0);
            },
            'g' => return self.makeToken(.escape_g, 0),
            'k' => return self.makeToken(.escape_k, 0),
            'Q' => {
                // Start literal sequence - treat everything as literal until \E.
                self.literal_mode = true;
                const next_c = self.advance() orelse return self.makeToken(.eof, 0);
                return self.literalTokenForCurrentCodepoint(next_c);
            },
            'E' => {
                // \E only valid inside \Q...\E literal sequence.
                if (!self.literal_mode) {
                    // Outside literal mode, \E is just literal 'E'.
                    return self.makeToken(.literal, 'E');
                }
                self.literal_mode = false;
                const next_c = self.advance() orelse return self.makeToken(.eof, 0);
                if (next_c == '\\') {
                    self.start_pos = self.pos - 1;
                    return try self.parseEscape();
                }
                return self.tokenForCurrentCodepoint(next_c);
            },
            '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                // Backreference \1, \2, etc.
                return self.makeToken(.backref, c - '0');
            },
            '\\', '.', '*', '+', '?', '|', '(', ')', '[', ']', '{', '}', '^', '$' => {
                // Literal escape of special characters
                return self.makeToken(.escaped_literal, c);
            },
            else => {
                // PCRE compatibility: unknown escapes treated as literals
                return self.makeToken(.escaped_literal, c);
            },
        };
    }

    pub fn next(self: *Lexer) RegexError!Token {
        self.start_pos = self.pos;
        self.skipExtendedTrivia();
        self.start_pos = self.pos;

        const c = self.advance() orelse {
            return self.makeToken(.eof, 0);
        };

        // In literal mode, treat everything as literal except \E
        if (self.literal_mode) {
            if (c == '\\') {
                const next_c = self.peek();
                if (next_c == 'E') {
                    // Let parseEscape handle \E to exit literal mode
                    return try self.parseEscape();
                }
                // In literal mode, backslash is literal
                return self.makeToken(.literal, c);
            }
            // Everything else is literal in literal mode
            return self.makeToken(.literal, c);
        }

        // Parse PCRE verbs: (*UTF), (*UCP), etc.
        if (c == '(' and self.peek() == '*') {
            return try self.parsePcreVerb();
        }

        // Parse PCRE inline comments: (?#...)
        // Must check BEFORE the switch to handle at the lexer level (transparent to parser)
        if (c == '(' and self.peek() == '?') {
            // peek one more character ahead
            const next_pos = self.pos + 1;
            if (next_pos < self.input.len and self.input[next_pos] == '#') {
                self.pos += 2; // skip past '?' and '#'
                // consume until ')'
                while (self.pos < self.input.len) : (self.pos += 1) {
                    if (self.input[self.pos] == ')') {
                        self.pos += 1; // consume ')'
                        break;
                    }
                }
                // tail-recurse: return the NEXT real token
                return self.next();
            }
        }

        return switch (c) {
            '\\' => try self.parseEscape(),
            else => self.tokenForConsumedCharWithSpan(c, self.start_pos, self.pos),
        };
    }

    fn parsePcreVerb(self: *Lexer) RegexError!Token {
        _ = self.advance(); // consume *
        const start = self.pos;

        // Consume until )
        while (self.peek()) |c| {
            if (c == ')') break;
            _ = self.advance();
        }

        const verb = self.input[start..self.pos];

        if (std.mem.eql(u8, verb, "UCP")) {
            self.flags.unicode = true;
            _ = self.advance(); // consume )
            return self.makeToken(.pcre_ucp, 0);
        } else if (std.mem.eql(u8, verb, "UTF") or std.mem.eql(u8, verb, "UTF8")) {
            self.flags.unicode = true;
            _ = self.advance(); // consume )
            return self.makeToken(.pcre_utf, 0);
        } else if (std.mem.eql(u8, verb, "BSR_UNICODE") or std.mem.eql(u8, verb, "BSR_ANYCRLF")) {
            // Accept and ignore (we support \R universally)
            _ = self.advance(); // consume )
            return self.makeToken(.pcre_ignore, 0);
        } else {
            return RegexError.PCREVerbsNotSupported;
        }
    }

    /// Extract raw content from `start_pos` up to (but not including) `stop_char`.
    /// Advances the lexer position past the stop character.
    /// Use this when the parser needs bracketed content (e.g. `\p{Latin}`, `\g{name}`)
    /// but the lexer's own position isn't at the opening brace.
    /// Returns the slice between start_pos and stop_char, or error if stop_char not found.
    pub fn extractRawUntilFrom(self: *Lexer, start_pos: usize, stop_char: u8) ![]const u8 {
        var end_pos = start_pos;
        while (end_pos < self.input.len and self.input[end_pos] != stop_char) {
            end_pos += 1;
        }
        if (end_pos >= self.input.len) return RegexError.UnexpectedCharacter;
        const result = self.input[start_pos..end_pos];
        self.pos = end_pos + 1; // Fast-forward past stop_char
        return result;
    }
};

/// Parser state for lifecycle tracking
const ParserState = enum {
    /// Parsing in progress, arena available for allocations
    parsing,
    /// Arena transferred to AST, no more allocations allowed
    finished,
};

/// Parser for regex patterns
pub const Parser = struct {
    lexer: Lexer,
    allocator: std.mem.Allocator,
    ast_arena: ?std.heap.ArenaAllocator,
    current_token: Token,
    capture_count: usize,
    nesting_depth: usize,
    recursion_depth: usize,
    flag_stack: std.ArrayList(common.CompileFlags),
    reset_stack: std.ArrayList(usize), // Track capture_count at (?| entry for branch reset groups
    open_groups: std.ArrayList(usize), // Stack of currently open capturing groups
    state: ParserState = .parsing,

    /// Maximum nesting depth increased to 255 to allow deep but bounded patterns
    /// (PCRE2 uses 250; we use 255 for compatibility)
    pub const MAX_NESTING_DEPTH: usize = 255;

    /// Maximum recursion depth to prevent stack overflow on large patterns
    /// Matches documentdb-main's PCRE2_RECURSION_LIMIT
    pub const MAX_RECURSION_DEPTH: usize = 4001;

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags) !Parser {
        var lexer = Lexer.init(pattern, flags);
        const first_token = try lexer.next();

        const ast_arena = std.heap.ArenaAllocator.init(allocator);

        var flag_stack = try std.ArrayList(common.CompileFlags).initCapacity(allocator, 1);
        try flag_stack.append(allocator, flags); // Push base flags

        const reset_stack = try std.ArrayList(usize).initCapacity(allocator, 1);
        const open_groups = try std.ArrayList(usize).initCapacity(allocator, 4);

        return .{
            .lexer = lexer,
            .allocator = allocator,
            .ast_arena = ast_arena,
            .current_token = first_token,
            .capture_count = 0,
            .nesting_depth = 0,
            .recursion_depth = 0,
            .flag_stack = flag_stack,
            .reset_stack = reset_stack,
            .open_groups = open_groups,
            .state = .parsing,
        };
    }

    /// Returns the allocator for AST nodes, always derived from the struct-owned arena.
    /// IMPORTANT: Never cache the result — always call this method to get a fresh allocator
    /// with a valid pointer to the arena inside this struct.
    /// Panics if called after parse() has completed (state = .finished)
    fn astAllocator(self: *Parser) std.mem.Allocator {
        std.debug.assert(self.state == .parsing);
        return self.ast_arena.?.allocator();
    }

    /// Creates a character class node from an escape sequence type.
    /// Eliminates need for 11 separate ranges_* temporary variables.
    fn createCharClassFromEscape(
        self: *Parser,
        comptime class_name: []const u8,
        token: Token,
    ) !*ast.Node {
        const class_info = @field(common.CharClasses, class_name);
        const ranges = try self.astAllocator().dupe(common.CharRange, class_info.ranges);
        const flags = self.currentFlags();
        return ast.Node.createCharClass(self.astAllocator(), .{
            .ranges = ranges,
            .negated = class_info.negated,
        }, flags.case_insensitive, token.span);
    }

    pub fn deinit(self: *Parser) void {
        if (self.ast_arena) |*arena| {
            arena.deinit();
        }
        self.flag_stack.deinit(self.allocator);
        self.reset_stack.deinit(self.allocator);
        self.open_groups.deinit(self.allocator);
    }

    pub fn currentFlags(self: *Parser) common.CompileFlags {
        return self.flag_stack.items[self.flag_stack.items.len - 1];
    }

    fn advance(self: *Parser) !void {
        self.current_token = try self.lexer.next();
    }

    fn peek(self: *Parser) TokenType {
        return self.current_token.token_type;
    }

    fn expect(self: *Parser, expected: TokenType) !void {
        if (self.current_token.token_type != expected) {
            return RegexError.UnexpectedCharacter;
        }
        try self.advance();
    }

    /// Parse the entire regex pattern
    pub fn parse(self: *Parser) !ast.AST {
        const root = try self.parseAlternation();

        // Verify all input was consumed
        if (self.peek() != .eof) {
            return switch (self.peek()) {
                .rparen => RegexError.UnmatchedParenthesis,
                .rbracket => RegexError.UnmatchedBracket,
                else => RegexError.UnexpectedCharacter,
            };
        }

        // Mark as finished BEFORE transferring arena
        // This prevents any accidental allocations after transfer
        self.state = .finished;

        // Transfer ownership of the arena to the AST struct
        const final_arena = self.ast_arena.?;
        self.ast_arena = null;
        return ast.AST.init(final_arena, root, self.capture_count);
    }

    /// Parse alternation (lowest precedence)
    fn parseAlternation(self: *Parser) !*ast.Node {
        // Track recursion depth to prevent stack overflow
        self.recursion_depth += 1;
        if (self.recursion_depth > MAX_RECURSION_DEPTH) {
            return RegexError.RecursionLimitExceeded;
        }
        defer self.recursion_depth -= 1;

        var nodes: std.ArrayList(*ast.Node) = .empty;
        defer nodes.deinit(self.allocator);

        const first = try self.parseConcat();
        try nodes.append(self.allocator, first);

        while (self.peek() == .pipe) {
            try self.advance(); // consume |
            const right = try self.parseConcat();
            try nodes.append(self.allocator, right);
        }

        if (nodes.items.len == 1) {
            return nodes.items[0];
        }

        // Build balanced binary tree to prevent stack overflow
        return self.buildBalancedTree(nodes.items, ast.Node.createAlternation);
    }

    /// Parse alternation with branch reset behavior for (?|...) groups
    /// Each branch resets capture_count to the value at (?| entry
    fn parseAlternationWithReset(self: *Parser) !*ast.Node {
        self.recursion_depth += 1;
        if (self.recursion_depth > MAX_RECURSION_DEPTH) {
            return RegexError.RecursionLimitExceeded;
        }
        defer self.recursion_depth -= 1;

        var nodes: std.ArrayList(*ast.Node) = .empty;
        defer nodes.deinit(self.allocator);

        const reset_point = self.reset_stack.items[self.reset_stack.items.len - 1];

        // Parse first branch
        const first = try self.parseConcat();
        try nodes.append(self.allocator, first);

        // Parse remaining branches, resetting capture_count at each |
        while (self.peek() == .pipe) {
            try self.advance(); // consume |

            // Reset capture_count to saved value
            self.capture_count = reset_point;

            const right = try self.parseConcat();
            try nodes.append(self.allocator, right);
        }

        if (nodes.items.len == 1) {
            return nodes.items[0];
        }

        return self.buildBalancedTree(nodes.items, ast.Node.createAlternation);
    }

    /// Parse concatenation
    fn parseConcat(self: *Parser) !*ast.Node {
        // Track recursion depth to prevent stack overflow
        self.recursion_depth += 1;
        if (self.recursion_depth > MAX_RECURSION_DEPTH) {
            return RegexError.RecursionLimitExceeded;
        }
        defer self.recursion_depth -= 1;

        var nodes: std.ArrayList(*ast.Node) = .empty;
        defer nodes.deinit(self.allocator);

        while (true) {
            const token_type = self.peek();
            if (token_type == .pipe or token_type == .rparen or token_type == .eof) {
                break;
            }

            const node = try self.parseRepeat();
            try nodes.append(self.allocator, node);
        }

        if (nodes.items.len == 0) {
            return ast.Node.createEmpty(self.astAllocator(), common.Span.init(self.lexer.pos, self.lexer.pos));
        }

        if (nodes.items.len == 1) {
            return nodes.items[0];
        }

        // Build balanced binary tree to prevent stack overflow (O(log N) depth instead of O(N))
        return self.buildBalancedTree(nodes.items, ast.Node.createConcat);
    }

    /// Parse repetition operators (*, +, ?, {m,n})
    fn parseRepeat(self: *Parser) !*ast.Node {
        // Track recursion depth to prevent stack overflow
        self.recursion_depth += 1;
        if (self.recursion_depth > MAX_RECURSION_DEPTH) {
            return RegexError.RecursionLimitExceeded;
        }
        defer self.recursion_depth -= 1;

        var node = try self.parsePrimary();
        const start = node.span.start;

        while (true) {
            const token_type = self.peek();
            const span = common.Span.init(start, self.current_token.span.end);

            switch (token_type) {
                .star, .plus, .question, .lbrace => {
                    // Reject quantifier applied directly to a zero-width assertion, anchor,
                    // or an already quantified node. Pattern like ^*, (?=foo)+, or a** is invalid in PCRE.
                    switch (node.node_type) {
                        .anchor, .lookahead, .lookbehind, .empty, .star, .plus, .optional, .repeat => return RegexError.InvalidQuantifier,
                        else => {},
                    }
                },
                else => {},
            }

            switch (token_type) {
                .star => {
                    try self.advance();
                    // Check for possessive (*+) or lazy (*?)
                    const mode: ast.Node.QuantifierMode = if (self.peek() == .plus) blk: {
                        try self.advance();
                        break :blk .possessive;
                    } else if (self.peek() == .question) blk: {
                        try self.advance();
                        break :blk .lazy;
                    } else .greedy;
                    node = try ast.Node.createStar(self.astAllocator(), node, mode, span);
                },
                .plus => {
                    try self.advance();
                    // Check for possessive (++) or lazy (+?)
                    const mode: ast.Node.QuantifierMode = if (self.peek() == .plus) blk: {
                        try self.advance();
                        break :blk .possessive;
                    } else if (self.peek() == .question) blk: {
                        try self.advance();
                        break :blk .lazy;
                    } else .greedy;
                    node = try ast.Node.createPlus(self.astAllocator(), node, mode, span);
                },
                .question => {
                    try self.advance();
                    // Check for possessive (?+) or lazy (??)
                    const mode: ast.Node.QuantifierMode = if (self.peek() == .plus) blk: {
                        try self.advance();
                        break :blk .possessive;
                    } else if (self.peek() == .question) blk: {
                        try self.advance();
                        break :blk .lazy;
                    } else .greedy;
                    node = try ast.Node.createOptional(self.astAllocator(), node, mode, span);
                },
                .lbrace => {
                    try self.advance(); // consume {

                    // Parse minimum with overflow protection
                    const MAX_QUANTIFIER: usize = 100_000; // Reasonable upper limit to prevent DoS
                    var min: usize = 0;
                    while (self.peek() == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                        const digit = self.current_token.value - '0';

                        // Check for multiplication overflow before computing
                        if (min > std.math.maxInt(usize) / 10) {
                            return RegexError.InvalidQuantifier;
                        }

                        const new_min = min * 10 + digit;

                        // Enforce reasonable maximum to prevent resource exhaustion
                        if (new_min > MAX_QUANTIFIER) {
                            return RegexError.InvalidQuantifier;
                        }

                        min = new_min;
                        try self.advance();
                    }

                    var max: ?usize = min; // Default: exactly min times

                    // Check for comma (range syntax)
                    if (self.peek() == .literal and self.current_token.value == ',') {
                        try self.advance(); // consume ,

                        // Check if there's a max value
                        if (self.peek() == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                            max = 0;
                            while (self.peek() == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                                const digit = self.current_token.value - '0';

                                // Check for multiplication overflow
                                if (max.? > std.math.maxInt(usize) / 10) {
                                    return RegexError.InvalidQuantifier;
                                }

                                const new_max = max.? * 10 + digit;

                                // Enforce reasonable maximum
                                if (new_max > MAX_QUANTIFIER) {
                                    return RegexError.InvalidQuantifier;
                                }

                                max = new_max;
                                try self.advance();
                            }
                        } else {
                            // {m,} means m or more (unbounded)
                            max = null;
                        }
                    }

                    try self.expect(.rbrace);

                    // Validate min <= max
                    if (max) |max_val| {
                        if (min > max_val) {
                            return RegexError.InvalidQuantifier;
                        }
                    }

                    const bounds = ast.RepeatBounds.init(min, max);
                    // Check for possessive ({n,m}+) or lazy ({n,m}?)
                    const mode: ast.Node.QuantifierMode = if (self.peek() == .plus) blk: {
                        try self.advance();
                        break :blk .possessive;
                    } else if (self.peek() == .question) blk: {
                        try self.advance();
                        break :blk .lazy;
                    } else .greedy;
                    node = try ast.Node.createRepeat(self.astAllocator(), node, bounds, mode, span);
                },
                else => break,
            }
        }

        return node;
    }

    /// Parse primary expressions (literals, groups, character classes)
    fn parsePrimary(self: *Parser) RegexError!*ast.Node {
        // Track recursion depth to prevent stack overflow
        self.recursion_depth += 1;
        if (self.recursion_depth > MAX_RECURSION_DEPTH) {
            return RegexError.RecursionLimitExceeded;
        }
        defer self.recursion_depth -= 1;

        const token = self.current_token;
        const span = token.span;

        switch (token.token_type) {
            .literal, .escaped_literal => {
                try self.advance();
                const flags = self.currentFlags();

                // Decode UTF-8 from raw input at token position
                // For escaped_literal, skip the backslash at span.start
                const pos = if (token.token_type == .escaped_literal) token.span.start + 1 else token.span.start;
                const byte_value = token.value;

                // ASCII fast path
                const c: common.Char = if (byte_value < 128)
                    byte_value
                else blk: {
                    // Decode UTF-8 for non-ASCII
                    if (pos >= self.lexer.input.len) break :blk byte_value;
                    const len = std.unicode.utf8ByteSequenceLength(self.lexer.input[pos]) catch break :blk byte_value;
                    if (pos + len > self.lexer.input.len) break :blk byte_value;
                    const codepoint = std.unicode.utf8Decode(self.lexer.input[pos .. pos + len]) catch break :blk byte_value;
                    break :blk codepoint;
                };

                return ast.Node.createLiteral(self.astAllocator(), c, flags.case_insensitive, span);
            },
            .dot => {
                try self.advance();
                const flags = self.currentFlags();
                return ast.Node.createAny(self.astAllocator(), flags.dot_all, span);
            },
            .caret => {
                try self.advance();
                const flags = self.currentFlags();
                return ast.Node.createAnchor(self.astAllocator(), .start_line, flags.multiline, span);
            },
            .dollar => {
                try self.advance();
                const flags = self.currentFlags();
                return ast.Node.createAnchor(self.astAllocator(), .end_line, flags.multiline, span);
            },
            .escape_d => {
                try self.advance();
                const flags = self.currentFlags();
                if (flags.unicode) {
                    return ast.Node.createCharClass(self.astAllocator(), .{
                        .ranges = &[_]common.CharRange{},
                        .negated = false,
                        .unicode_property = .digit,
                    }, flags.case_insensitive, token.span);
                }
                return self.createCharClassFromEscape("digit", token);
            },
            .escape_D => {
                try self.advance();
                const flags = self.currentFlags();
                if (flags.unicode) {
                    return ast.Node.createCharClass(self.astAllocator(), .{
                        .ranges = &[_]common.CharRange{},
                        .negated = true,
                        .unicode_property = .digit,
                    }, flags.case_insensitive, token.span);
                }
                return self.createCharClassFromEscape("non_digit", token);
            },
            .escape_w => {
                try self.advance();
                return self.createCharClassFromEscape("word", token);
            },
            .escape_W => {
                try self.advance();
                return self.createCharClassFromEscape("non_word", token);
            },
            .escape_s => {
                try self.advance();
                return self.createCharClassFromEscape("whitespace", token);
            },
            .escape_S => {
                try self.advance();
                return self.createCharClassFromEscape("non_whitespace", token);
            },
            .escape_h => {
                try self.advance();
                return self.createCharClassFromEscape("horizontal_whitespace", token);
            },
            .escape_H => {
                try self.advance();
                return self.createCharClassFromEscape("non_horizontal_whitespace", token);
            },
            .escape_v => {
                try self.advance();
                return self.createCharClassFromEscape("vertical_whitespace", token);
            },
            .escape_V => {
                try self.advance();
                return self.createCharClassFromEscape("non_vertical_whitespace", token);
            },
            .escape_R => {
                try self.advance();
                const r_span = token.span;

                // Expand \R to atomic alternation: (?>\r\n|\r|\n|\u0085|\u2028|\u2029)
                // Per PCRE2 spec: \R = (?>\r\n|\n|\x0b|\f|\r|\x85)
                // Order matters: CRLF must be tried first!

                const crlf = try ast.Node.createConcat(self.astAllocator(), try ast.Node.createLiteral(self.astAllocator(), '\r', false, r_span), try ast.Node.createLiteral(self.astAllocator(), '\n', false, r_span), r_span);
                const lf = try ast.Node.createLiteral(self.astAllocator(), '\n', false, r_span);
                const vt = try ast.Node.createLiteral(self.astAllocator(), 0x0B, false, r_span); // \x0b
                const ff = try ast.Node.createLiteral(self.astAllocator(), 0x0C, false, r_span); // \f
                const cr = try ast.Node.createLiteral(self.astAllocator(), '\r', false, r_span);
                const nel = try ast.Node.createLiteral(self.astAllocator(), 0x0085, false, r_span);
                const ls = try ast.Node.createLiteral(self.astAllocator(), 0x2028, false, r_span);
                const ps = try ast.Node.createLiteral(self.astAllocator(), 0x2029, false, r_span);

                // Build alternation: crlf | lf | vt | ff | cr | nel | ls | ps
                var alt = try ast.Node.createAlternation(self.astAllocator(), crlf, lf, r_span);
                alt = try ast.Node.createAlternation(self.astAllocator(), alt, vt, r_span);
                alt = try ast.Node.createAlternation(self.astAllocator(), alt, ff, r_span);
                alt = try ast.Node.createAlternation(self.astAllocator(), alt, cr, r_span);
                alt = try ast.Node.createAlternation(self.astAllocator(), alt, nel, r_span);
                alt = try ast.Node.createAlternation(self.astAllocator(), alt, ls, r_span);
                alt = try ast.Node.createAlternation(self.astAllocator(), alt, ps, r_span);

                // Wrap in atomic group (prevents backtracking)
                return ast.Node.createAtomicGroup(self.astAllocator(), alt, r_span);
            },
            .escape_X => {
                try self.advance();
                const x_span = token.span;
                // \X matches an extended grapheme cluster
                return ast.Node.createExtendedGrapheme(self.astAllocator(), x_span);
            },
            .escape_b => {
                try self.advance();
                return ast.Node.createAnchor(self.astAllocator(), .word_boundary, self.currentFlags().multiline, span);
            },
            .escape_B => {
                try self.advance();
                return ast.Node.createAnchor(self.astAllocator(), .non_word_boundary, self.currentFlags().multiline, span);
            },
            .escape_p, .escape_P => {
                const is_negated = (self.current_token.token_type == .escape_P);
                const token_span = self.current_token.span;

                // Parse {PropertyName} from lexer input WITHOUT advancing first
                // The lexer has consumed \p and is now pointing at {
                const current_pos = self.lexer.pos;
                if (current_pos >= self.lexer.input.len or self.lexer.input[current_pos] != '{') {
                    return RegexError.InvalidUnicodeProperty;
                }

                // Lexer owns the raw input scanning and position advancement
                const prop_name = self.lexer.extractRawUntilFrom(current_pos + 1, '}') catch {
                    return RegexError.InvalidUnicodeProperty;
                };

                // Now advance to consume the escape_p token
                try self.advance();

                // Special case for \p{Any}
                if (std.mem.eql(u8, prop_name, "Any")) {
                    return ast.Node.createCharClass(self.astAllocator(), .{
                        .ranges = &[_]common.CharRange{},
                        .negated = is_negated,
                        .unicode_property = .any,
                    }, self.currentFlags().case_insensitive, token_span);
                }

                // Look up script
                const unicode_properties = @import("unicode_properties.zig");
                const script = unicode_properties.SCRIPT_BY_NAME.get(prop_name) orelse {
                    return RegexError.InvalidUnicodeProperty;
                };

                // Create CharClass with script property
                return ast.Node.createCharClass(self.astAllocator(), .{
                    .ranges = &[_]common.CharRange{},
                    .negated = is_negated,
                    .unicode_property = .{ .script = script },
                }, self.currentFlags().case_insensitive, token_span);
            },
            .escape_A => {
                try self.advance();
                return ast.Node.createAnchor(self.astAllocator(), .start_text, self.currentFlags().multiline, span);
            },
            .escape_z => {
                try self.advance();
                return ast.Node.createAnchor(self.astAllocator(), .end_text_strict, self.currentFlags().multiline, span);
            },
            .escape_Z => {
                try self.advance();
                return ast.Node.createAnchor(self.astAllocator(), .end_text_before_final_newline, self.currentFlags().multiline, span);
            },
            .escape_char => {
                try self.advance();
                return ast.Node.createLiteral(self.astAllocator(), token.value, self.currentFlags().case_insensitive, token.span);
            },
            .backref => {
                try self.advance();
                const index = token.value; // 1-based capture group index
                return ast.Node.createBackreference(self.astAllocator(), index, null, false, span);
            },
            .pcre_ucp, .pcre_utf => {
                try self.advance();
                // Update the current flags in the flag_stack to enable Unicode mode
                var current_flags = &self.flag_stack.items[self.flag_stack.items.len - 1];
                current_flags.unicode = true;
                // Return empty node (these verbs don't produce AST nodes)
                return ast.Node.createEmpty(self.astAllocator(), span);
            },
            .pcre_ignore => {
                try self.advance();
                return ast.Node.createEmpty(self.astAllocator(), span);
            },
            .escape_g => {
                // \g{name}, \g{1}, \g{-1}, \g{+1}, \g1 backreferences
                try self.advance(); // consume \g token

                if (self.current_token.token_type != .lbrace) {
                    // Support \g1 (without braces) - single digit only
                    if (self.current_token.token_type == .literal and self.current_token.value >= '1' and self.current_token.value <= '9') {
                        const num: usize = self.current_token.value - '0';
                        try self.advance();
                        return ast.Node.createBackreference(self.astAllocator(), num, null, false, span);
                    }
                    return RegexError.UnexpectedCharacter;
                }

                try self.advance(); // consume {

                var is_negative = false;
                var is_relative_positive = false;

                if (self.current_token.token_type == .literal and self.current_token.value == '-') {
                    is_negative = true;
                    try self.advance();
                } else if (self.current_token.token_type == .plus) {
                    is_relative_positive = true;
                    try self.advance();
                }

                if (self.current_token.token_type == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                    var num: usize = 0;
                    while (self.current_token.token_type == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                        if (num > std.math.maxInt(usize) / 10) return RegexError.UnexpectedCharacter;
                        num = num * 10 + (self.current_token.value - '0');
                        try self.advance();
                    }
                    try self.expect(.rbrace);

                    if (is_negative) {
                        if (num > self.capture_count) return RegexError.UnexpectedCharacter;
                        const resolved = self.capture_count + 1 - num;
                        return ast.Node.createBackreference(self.astAllocator(), resolved, null, false, span);
                    } else if (is_relative_positive) {
                        const resolved = self.capture_count + num;
                        // Forward relative ref: group not yet matched → empty-match semantics
                        return ast.Node.createBackreference(self.astAllocator(), resolved, null, true, span);
                    } else {
                        return ast.Node.createBackreference(self.astAllocator(), num, null, false, span);
                    }
                } else {
                    // Named backreference \g{name} - extract content between braces.
                    // Lexer owns the raw input scanning and position advancement.
                    const name = try self.lexer.extractRawUntilFrom(self.current_token.span.start, '}');
                    try self.advance(); // sync current_token
                    try self.advance(); // sync current_token
                    return ast.Node.createBackreference(self.astAllocator(), 0, name, false, span);
                }
            },
            .escape_k => {
                // \k<name>  (Perl), \k'name' (Perl), \k{name} (.NET)
                // All are named backreferences per PCRE2 spec - produces same node as \g{name}
                try self.advance(); // consume \k token

                // Determine delimiter style
                const open_delim: u8 = switch (self.current_token.token_type) {
                    .literal => self.current_token.value,
                    .lbrace => '{',
                    else => return RegexError.InvalidGroupName,
                };
                const close_delim: u8 = switch (open_delim) {
                    '<' => '>',
                    '\'' => '\'',
                    '{' => '}',
                    else => return RegexError.InvalidGroupName,
                };

                try self.advance(); // consume < or ' or {

                // Read name characters until close delimiter
                const name = try self.parseNameUntil(&[_]u8{close_delim});

                // Consume closing delimiter
                if (self.current_token.token_type == .literal and self.current_token.value == close_delim) {
                    try self.advance();
                } else if (self.current_token.token_type == .rbrace and close_delim == '}') {
                    try self.advance();
                } else {
                    return RegexError.InvalidGroupName;
                }

                return ast.Node.createBackreference(self.astAllocator(), 0, name, false, span);
            },
            .lparen => {
                // SECURITY: Check nesting depth to prevent stack overflow
                self.nesting_depth += 1;
                if (self.nesting_depth > MAX_NESTING_DEPTH) {
                    return RegexError.NestingTooDeep;
                }
                defer self.nesting_depth -= 1;

                try self.advance(); // consume (

                // Check for group extensions (?...)
                var capture_index: ?usize = null;
                var group_name: ?[]const u8 = null;

                if (self.current_token.token_type == .question) {
                    try self.advance(); // consume ?

                    // Check for branch reset group (?|...)
                    if (self.current_token.token_type == .pipe) {
                        try self.advance(); // consume |

                        // Save current capture_count for reset
                        try self.reset_stack.append(self.allocator, self.capture_count);
                        defer _ = self.reset_stack.pop();

                        // Parse alternation with reset behavior
                        const child = try self.parseAlternationWithReset();
                        try self.expect(.rparen);

                        // Branch reset group is non-capturing
                        return ast.Node.createGroup(self.astAllocator(), child, null, span);
                    }

                    // Check for conditional pattern (?(...)yes|no)
                    if (self.current_token.token_type == .lparen) {
                        try self.advance(); // consume (

                        const is_assertion = self.current_token.token_type == .question;

                        const condition = blk: {
                            if (self.current_token.token_type == .question) {
                                // Assertion condition (?(?=...)yes|no) or (?(?!...)yes|no)
                                try self.advance(); // consume ?

                                if (self.current_token.token_type != .literal) {
                                    return RegexError.UnexpectedCharacter;
                                }

                                const is_positive = if (self.current_token.value == '=') true else if (self.current_token.value == '!') false else return RegexError.UnexpectedCharacter;

                                try self.advance(); // consume = or !
                                const child = try self.parseAlternation();
                                try self.expect(.rparen); // consume ) after assertion

                                const assertion_node = try ast.Node.createLookahead(self.astAllocator(), child, is_positive, span);
                                break :blk ast.Node.ConditionType{ .assertion = assertion_node };
                            } else if (self.current_token.token_type == .literal and (self.current_token.value == '<' or self.current_token.value == '\'')) {
                                // Named group condition (?(<name>)yes|no) or (?('name')yes|no)
                                const quote_char = self.current_token.value;
                                try self.advance(); // consume < or '
                                const name = try self.parseGroupName();
                                if (quote_char == '\'') {
                                    if (self.current_token.token_type != .literal or self.current_token.value != '\'') {
                                        return RegexError.UnexpectedCharacter;
                                    }
                                    try self.advance(); // consume closing '
                                }
                                break :blk ast.Node.ConditionType{ .group_name = name };
                            } else if (self.current_token.token_type == .literal) {
                                // Group number condition (?(1)yes|no)
                                var num: usize = 0;
                                while (self.current_token.token_type == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                                    num = num * 10 + (self.current_token.value - '0');
                                    try self.advance();
                                }
                                break :blk ast.Node.ConditionType{ .group_number = num };
                            } else {
                                return RegexError.UnexpectedCharacter;
                            }
                        };

                        if (!is_assertion) {
                            try self.expect(.rparen); // consume ) after condition (not for assertions)
                        }

                        const yes_branch = try self.parseConcat();

                        const no_branch = if (self.current_token.token_type == .pipe) blk: {
                            try self.advance(); // consume |
                            const no = try self.parseConcat();
                            break :blk no;
                        } else null;

                        try self.expect(.rparen);
                        return ast.Node.createConditional(self.astAllocator(), condition, yes_branch, no_branch, span);
                    }

                    // Check for inline modifiers: (?i), (?-i), (?i:...), (?im), etc.
                    if (self.current_token.token_type == .literal) {
                        const c = self.current_token.value;
                        if (c == 'i' or c == 'm' or c == 's' or c == 'x' or c == '-') {
                            // Parse inline modifiers
                            var enable = true;
                            var new_flags = self.currentFlags();
                            var is_modifier_only = false;

                            while (self.current_token.token_type == .literal) {
                                const flag_char = self.current_token.value;
                                if (flag_char == '-') {
                                    enable = false;
                                    try self.advance();
                                } else if (flag_char == 'i') {
                                    new_flags.case_insensitive = enable;
                                    try self.advance();
                                } else if (flag_char == 'm') {
                                    new_flags.multiline = enable;
                                    try self.advance();
                                } else if (flag_char == 's') {
                                    new_flags.dot_all = enable;
                                    try self.advance();
                                } else if (flag_char == 'x') {
                                    new_flags.extended = enable;
                                    try self.advance();
                                } else if (flag_char == ':') {
                                    // Scoped modifier (?i:...)
                                    try self.advance(); // consume :
                                    try self.flag_stack.append(self.allocator, new_flags);
                                    defer _ = self.flag_stack.pop();

                                    const child = try self.parseAlternation();
                                    try self.expect(.rparen);
                                    return ast.Node.createGroup(self.astAllocator(), child, null, span);
                                } else {
                                    // Not a flag character, break
                                    break;
                                }
                            }

                            // Check if it's a pure modifier (?i) or scoped (?i:...)
                            if (self.current_token.token_type == .rparen) {
                                // Pure modifier (?i) - modifies parent scope
                                is_modifier_only = true;
                                try self.advance(); // consume )

                                // Modify the parent scope's flags (top of stack)
                                self.flag_stack.items[self.flag_stack.items.len - 1] = new_flags;

                                // Synchronize Lexer's flags so it knows to skip whitespace in (?x) mode
                                self.lexer.flags = new_flags;

                                // Return empty node (modifier doesn't consume input)
                                return ast.Node.createEmpty(self.astAllocator(), span);
                            }
                        }
                    }

                    // Check what follows the ?
                    if (self.current_token.token_type == .literal or self.current_token.token_type == .plus) {
                        if (self.current_token.token_type == .literal and self.current_token.value == ':') {
                            // Non-capturing group (?:...)
                            try self.advance(); // consume :
                            // capture_index remains null
                        } else if (self.current_token.token_type == .literal and self.current_token.value == '=') {
                            // Positive lookahead (?=...)
                            try self.advance(); // consume =
                            const child = try self.parseAlternation();
                            try self.expect(.rparen);
                            return ast.Node.createLookahead(self.astAllocator(), child, true, span);
                        } else if (self.current_token.token_type == .literal and self.current_token.value == '!') {
                            // Negative lookahead (?!...)
                            try self.advance(); // consume !
                            const child = try self.parseAlternation();
                            try self.expect(.rparen);
                            return ast.Node.createLookahead(self.astAllocator(), child, false, span);
                        } else if (self.current_token.token_type == .literal and self.current_token.value == '>') {
                            // Atomic group (?>...)
                            try self.advance(); // consume >
                            const child = try self.parseAlternation();
                            try self.expect(.rparen);
                            return ast.Node.createAtomicGroup(self.astAllocator(), child, span);
                        } else if (self.current_token.token_type == .literal and (self.current_token.value == 'R' or self.current_token.value == '0')) {
                            // Recursive pattern: (?R) or (?0) - recurse entire pattern
                            try self.advance(); // consume R or 0
                            const keep_groups = try self.parseRecursionKeepList();
                            try self.expect(.rparen);
                            return ast.Node.createRecursion(self.astAllocator(), .{ .kind = .whole_pattern, .keep_groups = keep_groups }, span);
                        } else if (self.current_token.token_type == .plus or (self.current_token.token_type == .literal and self.current_token.value == '-')) {
                            // Positive or negative relative recursion: (?+1), (?-2)
                            const is_negative = self.current_token.token_type == .literal and self.current_token.value == '-';
                            try self.advance(); // consume + or -
                            var num: usize = 0;
                            while (self.current_token.token_type == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                                if (num > std.math.maxInt(usize) / 10) return RegexError.UnexpectedCharacter;
                                num = num * 10 + (self.current_token.value - '0');
                                try self.advance();
                            }
                            if (num == 0) return RegexError.UnexpectedCharacter;
                            if (is_negative and num > self.capture_count + 1) {
                                return RegexError.UnexpectedCharacter;
                            }
                            const resolved = if (is_negative) self.capture_count + 1 - num else self.capture_count + num;
                            const keep_groups = try self.parseRecursionKeepList();
                            try self.expect(.rparen);
                            return ast.Node.createRecursion(self.astAllocator(), .{ .kind = .{ .group_number = resolved }, .keep_groups = keep_groups }, span);
                        } else if (self.current_token.token_type == .literal and self.current_token.value >= '1' and self.current_token.value <= '9') {
                            // Recursive pattern: (?1), (?2), etc. - recurse specific group
                            var num: usize = 0;
                            while (self.current_token.token_type == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                                num = num * 10 + (self.current_token.value - '0');
                                try self.advance();
                            }
                            const keep_groups = try self.parseRecursionKeepList();
                            try self.expect(.rparen);
                            return ast.Node.createRecursion(self.astAllocator(), .{ .kind = .{ .group_number = num }, .keep_groups = keep_groups }, span);
                        } else if (self.current_token.token_type == .literal and self.current_token.value == '&') {
                            // Perl-style named recursion (?&name)
                            try self.advance(); // consume &
                            const name = try self.parseNameUntil("()");
                            const keep_groups = try self.parseRecursionKeepList();
                            try self.expect(.rparen);
                            return ast.Node.createRecursion(self.astAllocator(), .{ .kind = .{ .group_name = name }, .keep_groups = keep_groups }, span);
                        } else if (self.current_token.token_type == .literal and self.current_token.value == 'P') {
                            try self.advance(); // consume P
                            if (self.current_token.token_type == .literal and self.current_token.value == '>') {
                                // Python-style named subroutine (?P>name)
                                try self.advance(); // consume >
                                const name = try self.parseNameUntil("()");
                                const keep_groups = try self.parseRecursionKeepList();
                                try self.expect(.rparen);
                                return ast.Node.createRecursion(self.astAllocator(), .{ .kind = .{ .group_name = name }, .keep_groups = keep_groups }, span);
                            } else if (self.current_token.token_type == .literal and self.current_token.value == '<') {
                                // Python-style named group (?P<name>...)
                                try self.advance(); // consume <
                                group_name = try self.parseGroupName();
                                self.capture_count += 1;
                                capture_index = self.capture_count;
                            } else {
                                return RegexError.UnexpectedCharacter;
                            }
                        } else if (self.current_token.token_type == .literal and self.current_token.value == '<') {
                            // Check if it's lookbehind or named group
                            // Need to peek ahead to distinguish (?<=...) from (?<name>...)
                            const saved_pos = self.lexer.pos;
                            const saved_token = self.current_token;
                            try self.advance(); // consume <

                            if (self.current_token.token_type == .literal) {
                                if (self.current_token.value == '=') {
                                    // Positive lookbehind (?<=...)
                                    try self.advance(); // consume =
                                    const child = try self.parseAlternation();
                                    try self.expect(.rparen);
                                    return ast.Node.createLookbehind(self.astAllocator(), child, true, span);
                                } else if (self.current_token.value == '!') {
                                    // Negative lookbehind (?<!...)
                                    try self.advance(); // consume !
                                    const child = try self.parseAlternation();
                                    try self.expect(.rparen);
                                    return ast.Node.createLookbehind(self.astAllocator(), child, false, span);
                                } else {
                                    // .NET/Perl-style named group (?<name>...)
                                    // Restore position to re-parse the name
                                    self.lexer.pos = saved_pos;
                                    self.current_token = saved_token;
                                    try self.advance(); // consume <
                                    group_name = try self.parseGroupName();
                                    self.capture_count += 1;
                                    capture_index = self.capture_count;
                                }
                            } else {
                                return RegexError.UnexpectedCharacter;
                            }
                        } else {
                            // Unknown group extension
                            return RegexError.UnexpectedCharacter;
                        }
                    } else {
                        // Invalid syntax after (?
                        return RegexError.UnexpectedCharacter;
                    }
                } else {
                    // Regular capturing group - assign capture index BEFORE parsing child
                    self.capture_count += 1;
                    capture_index = self.capture_count;
                }

                // Push to open_groups if capturing
                if (capture_index) |idx| {
                    try self.open_groups.append(self.allocator, idx);
                }

                // Push current flags for this group scope
                try self.flag_stack.append(self.allocator, self.currentFlags());
                defer _ = self.flag_stack.pop();

                const child = try self.parseAlternation();
                try self.expect(.rparen);

                // Pop from open_groups if capturing
                if (capture_index) |_| {
                    _ = self.open_groups.pop();
                }

                if (group_name) |name| {
                    return ast.Node.createNamedGroup(self.astAllocator(), child, capture_index, name, span);
                } else {
                    return ast.Node.createGroup(self.astAllocator(), child, capture_index, span);
                }
            },
            .lbracket => {
                return try self.parseCharClass();
            },
            else => {
                return RegexError.UnexpectedCharacter;
            },
        }
    }

    /// Parse a name until we hit any of the stop characters
    /// Used for both group names and subroutine names
    fn parseNameUntil(self: *Parser, stop_chars: []const u8) ![]const u8 {
        var name_buf: [64]u8 = undefined;
        var name_len: usize = 0;

        // Collect name characters until we hit a stop character
        while (self.current_token.token_type != .eof) {
            if (self.current_token.token_type == .literal) {
                const c = self.current_token.value;
                // Check if this is a stop character
                if (std.mem.indexOfScalar(u8, stop_chars, c) != null) {
                    break;
                }

                // Valid name characters: alphanumeric and underscore
                if ((c >= 'a' and c <= 'z') or
                    (c >= 'A' and c <= 'Z') or
                    (c >= '0' and c <= '9') or
                    c == '_')
                {
                    if (name_len >= name_buf.len) {
                        return RegexError.InvalidCharacterClass;
                    }
                    name_buf[name_len] = c;
                    name_len += 1;
                    try self.advance();
                } else {
                    return RegexError.InvalidCharacterClass;
                }
            } else if (self.current_token.token_type == .lparen) {
                // Check if ( is a stop character
                if (std.mem.indexOfScalar(u8, stop_chars, '(') != null) break;
                return RegexError.InvalidCharacterClass;
            } else if (self.current_token.token_type == .rparen) {
                // Check if ) is a stop character
                if (std.mem.indexOfScalar(u8, stop_chars, ')') != null) break;
                return RegexError.InvalidCharacterClass;
            } else {
                return RegexError.InvalidCharacterClass;
            }
        }

        if (name_len == 0) {
            return RegexError.InvalidCharacterClass;
        }

        // Allocate and copy name
        const name = try self.astAllocator().alloc(u8, name_len);
        @memcpy(name, name_buf[0..name_len]);
        return name;
    }

    /// Parse group name from (?P<name>...) or (?<name>...)
    /// Expects current token to be first character of name
    /// Consumes tokens until > is found
    fn parseGroupName(self: *Parser) ![]const u8 {
        const name = try self.parseNameUntil(">");
        try self.advance(); // consume >
        return name;
    }

    /// Parse the optional grouplist for (?R(n1,n2)) or (?1(n1,n2))
    /// e.g., (1,2,3), (+1,-2), (<name>,'name') - returns slice of KeepGroup
    /// Returns null if no grouplist present (current token is NOT lparen)
    fn parseRecursionKeepList(self: *Parser) !?[]const ast.Node.KeepGroup {
        if (self.current_token.token_type != .lparen) {
            return null;
        }
        try self.advance(); // consume '('

        const allocator = self.astAllocator();
        var group_list = try std.ArrayList(ast.Node.KeepGroup).initCapacity(allocator, 4);
        errdefer group_list.deinit(allocator);

        while (self.current_token.token_type != .eof) {
            if (self.current_token.token_type == .rparen) {
                try self.advance(); // consume ')'
                break;
            }

            // Relative offset: +1 or -2 (PCRE2 syntax)
            // NOTE: '+' is tokenized as .plus (line 234), not .literal
            // '-' falls through as .literal since it's not a special token
            if (self.current_token.token_type == .plus) {
                // Positive relative offset like +1, +2
                try self.advance(); // consume +
                var num: usize = 0;
                while (self.current_token.token_type == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                    if (num > std.math.maxInt(usize) / 10) return RegexError.UnexpectedCharacter;
                    num = num * 10 + (self.current_token.value - '0');
                    try self.advance();
                }
                if (num == 0) {
                    // +0 refers to the enclosing group at the call site (or 0 if top-level)
                    const resolved = if (self.open_groups.items.len > 0)
                        self.open_groups.items[self.open_groups.items.len - 1]
                    else
                        0;
                    try group_list.append(allocator, .{ .index = resolved });
                } else {
                    const resolved = self.capture_count + num;
                    try group_list.append(allocator, .{ .index = resolved });
                }
            } else if (self.current_token.token_type == .literal and self.current_token.value == '-') {
                // Negative relative offset like -1, -2
                try self.advance(); // consume -
                var num: usize = 0;
                while (self.current_token.token_type == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                    if (num > std.math.maxInt(usize) / 10) return RegexError.UnexpectedCharacter;
                    num = num * 10 + (self.current_token.value - '0');
                    try self.advance();
                }
                if (num == 0) {
                    // -0 is the same as +0 (enclosing group at call site)
                    const resolved = if (self.open_groups.items.len > 0)
                        self.open_groups.items[self.open_groups.items.len - 1]
                    else
                        0;
                    try group_list.append(allocator, .{ .index = resolved });
                } else {
                    if (num > self.capture_count + 1) return RegexError.UnexpectedCharacter;
                    const resolved = self.capture_count + 1 - num;
                    try group_list.append(allocator, .{ .index = resolved });
                }
            }
            // Absolute index: 1, 2, 3
            else if (self.current_token.token_type == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                var num: usize = 0;
                while (self.current_token.token_type == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                    if (num > std.math.maxInt(usize) / 10) return RegexError.UnexpectedCharacter;
                    num = num * 10 + (self.current_token.value - '0');
                    try self.advance();
                }
                try group_list.append(allocator, .{ .index = num });
            }
            // Named group: <name> or 'name'
            else if (self.current_token.token_type == .literal and (self.current_token.value == '<' or self.current_token.value == '\'')) {
                const close_quote: u8 = if (self.current_token.value == '<') '>' else '\'';
                try self.advance(); // consume < or '

                var name_buf: [64]u8 = undefined;
                var name_len: usize = 0;
                while (self.current_token.token_type == .literal and self.current_token.value != close_quote) {
                    if (name_len >= name_buf.len) return RegexError.InvalidGroupName;
                    name_buf[name_len] = self.current_token.value;
                    name_len += 1;
                    try self.advance();
                }
                if (self.current_token.token_type != .literal or self.current_token.value != close_quote) {
                    return RegexError.InvalidGroupName;
                }
                try self.advance(); // consume closing quote

                const name_dup = try allocator.dupe(u8, name_buf[0..name_len]);
                try group_list.append(allocator, .{ .name = name_dup });
            } else {
                return RegexError.UnexpectedCharacter;
            }

            if (self.current_token.token_type == .literal and self.current_token.value == ',') {
                try self.advance(); // consume ','
            } else if (self.current_token.token_type != .rparen) {
                return RegexError.UnexpectedCharacter;
            }
        }

        if (group_list.items.len == 0) {
            group_list.deinit(allocator);
            return null;
        }
        return try group_list.toOwnedSlice(allocator);
    }

    /// Get POSIX character class by name
    fn getPosixClass(self: *Parser, name: []const u8) !common.CharClass {
        const is_unicode = self.currentFlags().unicode;

        if (std.mem.eql(u8, name, "alnum")) {
            if (is_unicode) return common.CharClass{ .ranges = &[_]common.CharRange{}, .negated = false, .unicode_property = .alnum };
            return common.CharClasses.posix_alnum;
        }
        if (std.mem.eql(u8, name, "alpha")) {
            if (is_unicode) return common.CharClass{ .ranges = &[_]common.CharRange{}, .negated = false, .unicode_property = .letter };
            return common.CharClasses.posix_alpha;
        }
        if (std.mem.eql(u8, name, "digit")) {
            if (is_unicode) return common.CharClass{ .ranges = &[_]common.CharRange{}, .negated = false, .unicode_property = .digit };
            return common.CharClasses.posix_digit;
        }
        if (std.mem.eql(u8, name, "blank")) return common.CharClasses.posix_blank;
        if (std.mem.eql(u8, name, "cntrl")) return common.CharClasses.posix_cntrl;
        if (std.mem.eql(u8, name, "graph")) return common.CharClasses.posix_graph;
        if (std.mem.eql(u8, name, "lower")) return common.CharClasses.posix_lower;
        if (std.mem.eql(u8, name, "print")) return common.CharClasses.posix_print;
        if (std.mem.eql(u8, name, "punct")) return common.CharClasses.posix_punct;
        if (std.mem.eql(u8, name, "space")) return common.CharClasses.posix_space;
        if (std.mem.eql(u8, name, "upper")) return common.CharClasses.posix_upper;
        if (std.mem.eql(u8, name, "xdigit")) return common.CharClasses.posix_xdigit;
        return RegexError.InvalidCharacterClass;
    }

    /// Get literal character from token (special chars are literal inside [...])
    /// Uses "Token Contextual Coercion" - blacklist approach for future-proofing
    fn getCharClassChar(self: *Parser) ?common.Char {
        const t = self.current_token;

        // Explicit escapes that represent a single character
        if (t.token_type == .escape_char) return t.value;

        // Blacklist: Tokens that fundamentally CANNOT be coerced into a single literal character
        switch (t.token_type) {
            .eof, .escape_d, .escape_D, .escape_w, .escape_W, .escape_s, .escape_S, .escape_h, .escape_H, .escape_v, .escape_V, .escape_R, .escape_X, .escape_b, .escape_B, .escape_A, .escape_z, .escape_Z, .escape_p, .escape_P, .backref, .pcre_ucp, .pcre_utf => return null,
            else => {}, // Everything else (structural tokens, literals) can be safely coerced
        }

        // Extract the exact byte(s) the lexer saw from the source string
        // For escaped_literal tokens (like \]), skip the backslash at span.start
        const pos = if (t.token_type == .escaped_literal) t.span.start + 1 else t.span.start;
        if (pos >= self.lexer.input.len) return t.value;

        // Fast path for ASCII
        if (self.lexer.input[pos] < 128) {
            return self.lexer.input[pos];
        }

        // Decode UTF-8 sequence
        const len = std.unicode.utf8ByteSequenceLength(self.lexer.input[pos]) catch return t.value;
        if (pos + len > self.lexer.input.len) return t.value;
        return std.unicode.utf8Decode(self.lexer.input[pos .. pos + len]) catch t.value;
    }

    /// Parse character class [...]
    fn parseCharClass(self: *Parser) !*ast.Node {
        const start = self.current_token.span.start;
        const prev_extended_trivia = self.lexer.extended_trivia_enabled;
        self.lexer.extended_trivia_enabled = false;
        defer self.lexer.extended_trivia_enabled = prev_extended_trivia;

        try self.advance(); // consume '['

        var negated = false;
        if (self.peek() == .caret) {
            negated = true;
            try self.advance();
        }

        var ranges = try std.ArrayList(common.CharRange).initCapacity(self.astAllocator(), 0);
        defer ranges.deinit(self.astAllocator());

        var unicode_property: ?common.CharClass.UnicodeProperty = null;

        // PCRE rule: if ] is the first character after [ (or [^), it is literal ]
        if (self.peek() == .rbracket) {
            try ranges.append(self.astAllocator(), common.CharRange.init(']', ']'));
            try self.advance();
        }

        while (self.peek() != .rbracket and self.peek() != .eof) {
            // Check for POSIX character class [:name:]
            // Check if current token is '[' followed by ':'
            if (self.current_token.token_type == .lbracket) {
                const next_pos = self.lexer.pos;
                if (next_pos < self.lexer.input.len and
                    self.lexer.input[next_pos] == ':')
                {
                    // Found potential POSIX class [[:
                    var found_posix = false;
                    var i = next_pos + 1;
                    while (i + 1 < self.lexer.input.len) : (i += 1) {
                        if (self.lexer.input[i] == ':' and self.lexer.input[i + 1] == ']') {
                            // Found [:name:]
                            const class_name = self.lexer.input[next_pos + 1 .. i];

                            // Skip to after ':]'
                            self.lexer.pos = i + 2;
                            self.current_token = try self.lexer.next();

                            // Get the POSIX class
                            const posix_class = try self.getPosixClass(class_name);

                            // If POSIX class has unicode_property, store it
                            if (posix_class.unicode_property) |prop| {
                                unicode_property = prop;
                            } else {
                                // Otherwise, add the ranges
                                for (posix_class.ranges) |range| {
                                    try ranges.append(self.astAllocator(), range);
                                }
                            }

                            found_posix = true;
                            break;
                        }
                    }

                    if (found_posix) {
                        continue;
                    } else {
                        // Started like a POSIX class but did not find the closing :]
                        return RegexError.InvalidCharacterClass;
                    }
                }
            }

            const first_char = self.getCharClassChar() orelse {
                return RegexError.InvalidCharacterClass;
            };
            try self.advance();

            // Check for range (a-z)
            // '-' is only a range operator if there's a character after it
            if (self.peek() == .literal and self.current_token.value == '-') {
                // Look ahead to see if there's another character (not ])
                const saved_pos = self.lexer.pos;
                try self.advance(); // consume -

                if (self.peek() == .rbracket or self.peek() == .eof) {
                    // '-' at end of class, treat both first_char and '-' as literals
                    try ranges.append(self.astAllocator(), common.CharRange.init(first_char, first_char));
                    try ranges.append(self.astAllocator(), common.CharRange.init('-', '-'));
                } else {
                    // It's a range
                    const second_char = self.getCharClassChar() orelse {
                        // Not a valid char, backtrack and treat '-' as literal
                        self.lexer.pos = saved_pos;
                        try ranges.append(self.astAllocator(), common.CharRange.init(first_char, first_char));
                        continue;
                    };
                    try self.advance();

                    try ranges.append(self.astAllocator(), common.CharRange.init(first_char, second_char));
                }
            } else {
                // Single character
                try ranges.append(self.astAllocator(), common.CharRange.init(first_char, first_char));
            }
        }

        try self.expect(.rbracket);

        const char_class = common.CharClass{
            .ranges = try ranges.toOwnedSlice(self.astAllocator()),
            .negated = negated,
            .unicode_property = unicode_property,
        };

        const span = common.Span.init(start, self.current_token.span.end);
        return ast.Node.createCharClass(self.astAllocator(), char_class, self.currentFlags().case_insensitive, span);
    }

    /// Builds a balanced binary tree from a flat list of nodes to prevent stack overflow
    /// Reduces recursion depth from O(N) to O(log N)
    fn buildBalancedTree(
        self: *Parser,
        nodes: []*ast.Node,
        comptime createFn: fn (std.mem.Allocator, *ast.Node, *ast.Node, common.Span) RegexError!*ast.Node,
    ) RegexError!*ast.Node {
        if (nodes.len == 0) return error.InvalidPattern;
        if (nodes.len == 1) return nodes[0];

        const mid = nodes.len / 2;
        const left = try self.buildBalancedTree(nodes[0..mid], createFn);

        const right = try self.buildBalancedTree(nodes[mid..], createFn);

        const span = common.Span.init(left.span.start, right.span.end);
        return createFn(self.astAllocator(), left, right, span);
    }
};

test "lexer basic tokens" {
    var lexer = Lexer.init("a*b+c?", .{});

    const t1 = try lexer.next();
    try std.testing.expectEqual(TokenType.literal, t1.token_type);
    try std.testing.expectEqual(@as(u8, 'a'), t1.value);

    const t2 = try lexer.next();
    try std.testing.expectEqual(TokenType.star, t2.token_type);

    const t3 = try lexer.next();
    try std.testing.expectEqual(TokenType.literal, t3.token_type);
    try std.testing.expectEqual(@as(u8, 'b'), t3.value);

    const t4 = try lexer.next();
    try std.testing.expectEqual(TokenType.plus, t4.token_type);

    const t5 = try lexer.next();
    try std.testing.expectEqual(TokenType.literal, t5.token_type);

    const t6 = try lexer.next();
    try std.testing.expectEqual(TokenType.question, t6.token_type);
}

test "lexer escape sequences" {
    var lexer = Lexer.init("\\d\\w\\s\\n", .{});

    const t1 = try lexer.next();
    try std.testing.expectEqual(TokenType.escape_d, t1.token_type);

    const t2 = try lexer.next();
    try std.testing.expectEqual(TokenType.escape_w, t2.token_type);

    const t3 = try lexer.next();
    try std.testing.expectEqual(TokenType.escape_s, t3.token_type);

    const t4 = try lexer.next();
    try std.testing.expectEqual(TokenType.escape_char, t4.token_type);
    try std.testing.expectEqual(@as(u8, '\n'), t4.value);
}

test "parser simple literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator, "abc", .{});
    defer parser.deinit();
    var result = try parser.parse();
    defer result.deinit();

    try std.testing.expectEqual(ast.NodeType.concat, result.root.node_type);
}

test "parser alternation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator, "a|b", .{});
    defer parser.deinit();
    var result = try parser.parse();
    defer result.deinit();

    try std.testing.expectEqual(ast.NodeType.alternation, result.root.node_type);
}

test "parser star" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator, "a*", .{});
    defer parser.deinit();
    var result = try parser.parse();
    defer result.deinit();

    try std.testing.expectEqual(ast.NodeType.star, result.root.node_type);
}

test "parser group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator, "(ab)", .{});
    defer parser.deinit();
    var result = try parser.parse();
    defer result.deinit();

    try std.testing.expectEqual(ast.NodeType.group, result.root.node_type);
    try std.testing.expectEqual(@as(usize, 1), result.capture_count);
}

// Temporarily disabled - POSIX parsing needs redesign
test "POSIX character class parsing" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "[[:alpha:]]", .{});
    defer parser.deinit();
    var tree = try parser.parse();
    defer tree.deinit();

    try std.testing.expectEqual(ast.NodeType.char_class, tree.root.node_type);
}

test "parser: nesting depth limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a pattern with 256 levels of nesting (exceeds MAX_NESTING_DEPTH of 255)
    var pattern_buf: [600]u8 = undefined;
    var pos: usize = 0;

    // Write 256 opening parens
    for (0..256) |_| {
        pattern_buf[pos] = '(';
        pos += 1;
    }

    // Write 'a' in the middle
    pattern_buf[pos] = 'a';
    pos += 1;

    // Write 256 closing parens
    for (0..256) |_| {
        pattern_buf[pos] = ')';
        pos += 1;
    }

    const pattern = pattern_buf[0..pos];
    var parser = try Parser.init(allocator, pattern, .{});
    defer parser.deinit();
    const result = parser.parse();

    try std.testing.expectError(RegexError.NestingTooDeep, result);
}

test "parser: acceptable nesting depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a pattern with 50 levels of nesting (well within MAX_NESTING_DEPTH of 100)
    var pattern_buf: [200]u8 = undefined;
    var pos: usize = 0;

    // Write 50 opening parens
    for (0..50) |_| {
        pattern_buf[pos] = '(';
        pos += 1;
    }

    // Write 'a' in the middle
    pattern_buf[pos] = 'a';
    pos += 1;

    // Write 50 closing parens
    for (0..50) |_| {
        pattern_buf[pos] = ')';
        pos += 1;
    }

    const pattern = pattern_buf[0..pos];
    var parser = try Parser.init(allocator, pattern, .{});
    defer parser.deinit();
    var result = try parser.parse();
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 50), result.capture_count);
}
