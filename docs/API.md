# Public API

This document describes the **current public API** of the `zig-regex-mongo-compat` package as exported by `src/root.zig`.

It answers three concrete questions:

1. **What does `@import("regex")` expose?**
2. **Which APIs are intended for normal callers?**
3. **What are the current top-level flag and matching semantics?**

If behavior is not described here, do **not** treat it as stable public contract just because the current implementation happens to allow it.

---

## Package boundary

The Zig package exports a single public module:

```zig
const regex = @import("regex");
```

The public root is `src/root.zig`.

This package documents the **Zig library API** and the **embedded C API** exposed from this repository.

This document does **not** define the contract of external wrapper repositories or downstream database integration layers.

---

## Public module surface

The package currently re-exports the following declarations from `src/root.zig`.

### Core matching types

- `Regex`
- `Match`
- `MatchBuffer`
- `MatchCapture`
- `ExecutionSession`
- `SessionIterator`
- `Matcher`
- `RegexError`
- `ErrorContext`
- `ErrorHelper`

### Performance and profiling

- `Profiler`
- `ScopedTimer`

### Thread-safety helpers

- `thread_safety`
- `SharedRegex`
- `RegexCache`

### Builder and composition APIs

- `Builder`
- `Patterns`
- `Composer`

### Analysis, linting, and diagnostics

- `Lint`
- `ComplexityAnalyzer`
- `ASTOptimizer`
- `PrettyPrinter`
- `ASTStats`
- `NFAOptimizer`
- `NFAVisualizer`
- `pattern_analyzer`
- `PatternAnalyzer`
- `AnalysisResult`
- `RiskLevel`
- `analyzePattern`
- `analyzeAndValidate`

### Macros and advanced features

- `macros`
- `MacroRegistry`
- `CommonMacros`
- `named_captures`
- `NamedCaptureRegistry`
- `NamedMatch`
- `unicode`
- `UnicodeProperty`
- `unicode_properties`
- `Script`
- `advanced`
- `AtomicGroupNode`
- `ConditionalNode`
- `PossessiveQuantifier`

### C API and lower-level modules

- `c_api`
- `common`
- `parser`
- `compiler`
- `optimizer`
- `backtrack`
- `text_policy`
- `debug`
- `profiling`
- `version`

---

## Recommended entry points

Most callers should start with:

- `Regex.compile(...)`
- `Regex.compileWithFlags(...)`
- `Regex.isMatch(...)`
- `Regex.find(...)`
- `Regex.findAll(...)`
- `Regex.replace(...)`
- `Regex.replaceAll(...)`
- `Regex.split(...)`

For repeated matching with less allocation pressure, prefer:

- `Regex.session(...)`
- `Regex.matchBuffer(...)`
- `ExecutionSession.findInto(...)`
- `ExecutionSession.iterator(...)`

---

## `Regex`

`Regex` is the main compiled regex type.

### Compile

```zig
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex
pub fn compileWithFlags(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags) !Regex
```

Use `compile()` when you want default behavior.
Use `compileWithFlags()` when you want explicit top-level flags.

### Lifetime

```zig
pub fn deinit(self: *Regex) void
```

Always call `deinit()` on a compiled regex.

### Basic matching/searching

```zig
pub fn isMatch(self: *const Regex, input: []const u8) !bool
pub fn find(self: *const Regex, input: []const u8) !?Match
pub fn findInto(self: *const Regex, input: []const u8, buffer: *MatchBuffer) !bool
pub fn findAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match
```

### Replacement and splitting

```zig
pub fn replace(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8
pub fn replaceAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8
pub fn split(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![][]const u8
```

### Session-oriented API

```zig
pub fn session(self: *const Regex, allocator: std.mem.Allocator) !ExecutionSession
pub fn matchBuffer(self: *const Regex, allocator: std.mem.Allocator) !MatchBuffer
pub fn matcher(self: *const Regex, allocator: std.mem.Allocator) !Matcher
pub fn iterator(self: *const Regex, input: []const u8) MatchIterator
```

`matcher()` is a compatibility wrapper around `session()`.

`Regex.iterator(...)` provides an allocating iterator convenience API.
The concrete `MatchIterator` type is part of `regex.zig`, but it is not separately re-exported from `src/root.zig`; most callers should rely on type inference here.
For tighter loops and reusable scratch space, prefer `ExecutionSession.iterator(...)` plus `MatchBuffer`.

### Named captures

```zig
pub fn getCaptureIndex(self: *const Regex, name: []const u8) ?usize
pub fn getNamedCapture(self: *const Regex, match: *const Match, name: []const u8) ?[]const u8
```

---

## `Match`

A `Match` contains:

- `slice` — matched text
- `start` — byte start offset
- `end` — byte end offset
- `captures` — capture texts for numbered groups

```zig
pub fn deinit(self: Match, allocator: std.mem.Allocator) void
```

---

## `ExecutionSession`

`ExecutionSession` is the reusable matching session type returned by `Regex.session(...)`.

### Construction

```zig
pub fn session(self: *const Regex, allocator: std.mem.Allocator) !ExecutionSession
```

### Session methods

```zig
pub fn deinit(self: *ExecutionSession) void
pub fn setMaxSteps(self: *ExecutionSession, max_steps: usize) void
pub fn iterator(self: *ExecutionSession, input: []const u8) SessionIterator
pub fn isMatch(self: *ExecutionSession, input: []const u8) !bool
pub fn find(self: *ExecutionSession, input: []const u8) !?Match
pub fn findInto(self: *ExecutionSession, input: []const u8, buffer: *MatchBuffer) !bool
```

Notes:

- `setMaxSteps()` only affects the backtracking engine path.
- `Matcher` is a compatibility alias for `ExecutionSession`.

---

## `SessionIterator`

`SessionIterator` is the reusable iterator returned by `ExecutionSession.iterator(...)`.

It supports:

```zig
pub fn reset(self: *SessionIterator) void
pub fn nextInto(self: *SessionIterator, buffer: *MatchBuffer) !bool
pub fn next(self: *SessionIterator, allocator: std.mem.Allocator) !?Match
```

Use `nextInto(...)` with a reusable `MatchBuffer` for the lowest allocation overhead.

---

## Compile flags

Top-level flags are represented by:

```zig
pub const CompileFlags = packed struct {
    case_insensitive: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    extended: bool = false,
    unicode: bool = false,
}
```

### Current top-level flag semantics

- `case_insensitive` — case-insensitive matching
- `multiline` — `^` and `$` operate on line boundaries
- `dot_all` — `.` matches newlines
- `extended` — insignificant whitespace and `# ... end-of-line` comments are skipped by the lexer in extended mode outside character classes and outside `\Q...\E` literal sections
- `unicode` — enables the engine's current internal Unicode-sensitive behavior

### Important note on `unicode`

`unicode` is **not** documented as a universal “full Unicode mode for everything” switch.

What it currently affects includes:

- Unicode-aware word-boundary policy (`\\b`, `\\B` via `text_policy`)
- Unicode-aware `\\d` / `\\D`
- Unicode-aware `\\w` / `\\W`
- compatibility with pattern-level `(*UCP)` / `(*UTF)` verbs, which currently set the same internal Unicode flag

Do **not** assume every escape or class becomes Unicode-aware just because `.unicode = true`, but `\\d`, `\\D`, `\\w`, `\\W`, `\\b`, and `\\B` are now aligned with the current internal Unicode word/digit policies.

### Native string flag parsing

`common.CompileFlags.parse(flags_str)` parses the native engine-facing string flags:

- `i`
- `m`
- `s`
- `x`
- `u`

Unknown flags return `error.InvalidFlags`.

This native parser preserves direct engine semantics, including `u -> .unicode = true`.

---

## `common.MongoExternalOptions`

The `common` module also exports a helper for parsing Mongo-style external option strings:

```zig
pub const MongoExternalOptions = struct {
    compile_flags: CompileFlags,

    pub fn parse(flags_str: []const u8) !MongoExternalOptions
    pub fn canonicalSlice(self: *const MongoExternalOptions) []const u8
}
```

This helper exists for consumers who need Mongo-style option parsing semantics.

### Mongo-style option rules implemented by this helper

Accepted option letters:

- `i`
- `m`
- `s`
- `x`
- `u`

Behavior:

- unknown flags are errors
- order is irrelevant
- duplicates are ignored
- `u` is accepted but treated as redundant by this helper
- `canonicalSlice()` returns a canonicalized `i`, `m`, `s`, `x`-ordered cache-friendly representation with redundant `u` removed

Examples:

- `"im"` and `"mi"` are equivalent
- `"ii"` is equivalent to `"i"`
- `"u"` is valid and canonicalizes to `""`
- `"g"` is invalid

This helper is part of the library, but it is **not** the primary compile path for normal Zig callers. Normal Zig callers can pass typed `CompileFlags` directly.

---

## Pattern-language ownership

Regex syntax and pattern semantics are engine-owned.

That includes, among other things:

- inline modifiers: `(?i)`, `(?m)`, `(?s)`, `(?x)`, `(?-i)`
- PCRE verbs: `(*UTF)`, `(*UCP)`
- Unicode properties: `\p{...}`, `\P{...}`
- lookahead / lookbehind
- recursion and subroutines
- backreferences and named captures
- grapheme matching `\X`
- anchor semantics such as `\A`, `\z`, `\Z`

---

## Input validity guarantees

### Patterns

Patterns containing an internal null byte are invalid.

### Native string flags

Unknown native string flags are invalid.

### Mongo-style external options helper

Unknown Mongo-style external option flags are invalid.

---

## Error model

Public callers should expect high-level failures such as:

- invalid pattern
- invalid flags
- invalid UTF-8 (where strict validation is required by the selected execution policy)
- unsupported or not-yet-implemented regex feature
- timeout / backtracking abort protection
- allocation failure

Do not build logic that depends on undocumented internal parser/compiler error distinctions unless you control both sides of the integration.

---

## C API

The repository also exports a small C API from `src/c_api.zig`.

### Exported C functions

- `zig_regex_compile`
- `zig_regex_free`
- `zig_regex_is_match`
- `zig_regex_find`
- `zig_match_get_text`
- `zig_match_get_start`
- `zig_match_get_end`
- `zig_match_free`
- `zig_regex_version`

### Important C API note

`zig_match_get_text()` currently returns a pointer into the match slice and assumes null termination.
That is a real limitation of the current C API and should be treated carefully by foreign callers.

---

## Examples

### Basic compile and match

```zig
const std = @import("std");
const regex = @import("regex");

test "basic match" {
    const allocator = std.testing.allocator;

    var re = try regex.Regex.compile(allocator, "abc");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("xyzabcxyz"));
}
```

### Compile with flags

```zig
const std = @import("std");
const regex = @import("regex");

test "top-level flags" {
    const allocator = std.testing.allocator;

    var re = try regex.Regex.compileWithFlags(allocator, "^a.b$", .{
        .case_insensitive = true,
        .multiline = true,
        .dot_all = true,
        .extended = true,
    });
    defer re.deinit();

    try std.testing.expect(try re.isMatch("A\nB"));
}
```

### Reusable session and buffer

```zig
const std = @import("std");
const regex = @import("regex");

test "session with reusable buffer" {
    const allocator = std.testing.allocator;

    var re = try regex.Regex.compile(allocator, "\\d+");
    defer re.deinit();

    var session = try re.session(allocator);
    defer session.deinit();

    var buffer = try re.matchBuffer(allocator);
    defer buffer.deinit();

    try std.testing.expect(try session.findInto("abc123def", &buffer));
    try std.testing.expectEqualStrings("123", buffer.slice);
}
```

### Mongo-style external option parsing helper

```zig
const std = @import("std");
const regex = @import("regex");

test "mongo-style external options helper" {
    const parsed = try regex.common.MongoExternalOptions.parse("uimsi");

    try std.testing.expect(parsed.compile_flags.case_insensitive);
    try std.testing.expect(parsed.compile_flags.multiline);
    try std.testing.expect(parsed.compile_flags.dot_all);
    try std.testing.expect(!parsed.compile_flags.unicode);
    try std.testing.expectEqualStrings("ims", parsed.canonicalSlice());
}
```

---

## Current known semantic caveats

If you are evaluating strict Mongo or strict PCRE2 parity, keep these caveats in mind:

1. Native `CompileFlags.parse("u")` still intentionally enables `.unicode`
2. Unicode-sensitive behavior is improved for `\\d`, `\\D`, `\\w`, `\\W`, `\\b`, and `\\B`, but broader Unicode/PCRE parity still depends on the rest of the engine surface
3. Some PCRE features remain intentionally unsupported or not implemented

That does **not** make the library unstable; it just means callers should avoid over-claiming compatibility beyond what is explicitly documented.

---

## Source of truth

When this document and other prose disagree, prefer the code in this order:

1. `src/root.zig` for exported module surface
2. `src/regex.zig` for core matching APIs
3. `src/common.zig` for flag types and parsing helpers
4. `src/parser.zig` for top-level lexical and syntax behavior
5. `src/c_api.zig` for the embedded C API

---

**Last updated:** 2026-03-30
**Package version in code:** `0.1.0`
