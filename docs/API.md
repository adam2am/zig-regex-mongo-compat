# Public API

This document defines the **supported public API** for `zig-regex-mongo-compat`.

It exists to answer two questions explicitly:

1. **What is publicly exposed by the Zig package?**
2. **What external regex flag contract is stable for Mongo-compatible integrations?**

If behavior is not described here, do **not** treat it as stable API just because the current parser happens to accept it.

---

## Package boundary

The `zig build` package exports the Zig module:

```zig
const regex = @import("regex");
```

The public root is `src/root.zig`.

### Publicly exported module surface

The package currently re-exports these declarations from `src/root.zig`:

- `Regex`
- `Match`
- `MatchBuffer`
- `MatchCapture`
- `ExecutionSession`
- `SessionIterator`
- `Matcher` (compatibility alias)
- `RegexError`
- `ErrorContext`
- `ErrorHelper`
- `Profiler`
- `ScopedTimer`
- `SharedRegex`
- `RegexCache`
- `Builder`
- `Patterns`
- `Composer`
- `Lint`
- `ComplexityAnalyzer`
- `MacroRegistry`
- `CommonMacros`
- `ASTOptimizer`
- `PrettyPrinter`
- `ASTStats`
- `NFAOptimizer`
- `NFAVisualizer`
- `NamedCaptureRegistry`
- `NamedMatch`
- `UnicodeProperty`
- `Script`
- `AtomicGroupNode`
- `ConditionalNode`
- `PossessiveQuantifier`
- `PatternAnalyzer`
- `AnalysisResult`
- `RiskLevel`
- `analyzePattern`
- `analyzeAndValidate`
- `c_api`
- internal/advanced namespaces re-exported for power users: `common`, `parser`, `compiler`, `optimizer`, `backtrack`, `text_policy`, `debug`, `profiling`, `unicode`, `unicode_properties`, `advanced`, `named_captures`, `pattern_analyzer`, `macros`, `thread_safety`

### Not part of the packaged Zig module API

The SQLite/BSON helper integration code (`bson_regex(...)`, `puresqlite_regex(...)`, SQLite extension entrypoints, JSON-path extraction, wrapper cache behavior) is **companion integration code**, not part of the package built by `build.zig`.

That code may be documented here for interoperability, but it should be treated as a **wrapper contract**, not as the core Zig package API.

---

## Core type: `Regex`

`Regex` is the primary compiled regex type.

### Compile

```zig
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex
pub fn compileWithFlags(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags) !Regex
```

Use `compile()` for default behavior and `compileWithFlags()` when you need explicit top-level flags.

#### Example

```zig
const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var re = try regex.Regex.compileWithFlags(allocator, "^hello", .{
        .case_insensitive = true,
        .multiline = true,
    });
    defer re.deinit();

    const ok = try re.isMatch("HELLO\nworld");
    _ = ok;
}
```

### Lifetime

```zig
pub fn deinit(self: *Regex) void
```

Always call `deinit()` on a compiled regex.

### Matching/search APIs

```zig
pub fn isMatch(self: *const Regex, input: []const u8) !bool
pub fn find(self: *const Regex, input: []const u8) !?Match
pub fn findInto(self: *const Regex, input: []const u8, buffer: *MatchBuffer) !bool
pub fn findAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![]Match
pub fn replace(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8
pub fn replaceAll(self: *const Regex, allocator: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8
pub fn split(self: *const Regex, allocator: std.mem.Allocator, input: []const u8) ![][]const u8
```

### Session-oriented API

For repeated matching, prefer creating a reusable session:

```zig
pub fn session(self: *const Regex, allocator: std.mem.Allocator) !ExecutionSession
pub fn matchBuffer(self: *const Regex, allocator: std.mem.Allocator) !MatchBuffer
pub fn matcher(self: *const Regex, allocator: std.mem.Allocator) !Matcher
pub fn iterator(self: *const Regex, input: []const u8) MatchIterator
```

`Matcher` is a compatibility alias for `ExecutionSession`.

---

## `Match`

A `Match` contains:

- `slice`: the matched text
- `start`: byte start offset
- `end`: byte end offset
- `captures`: capture texts for numbered groups

```zig
pub fn deinit(self: Match, allocator: std.mem.Allocator) void
```

---

## Compile flags

The top-level flag structure is:

```zig
pub const CompileFlags = packed struct {
    case_insensitive: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    extended: bool = false,
    unicode: bool = false,
}
```

These flags are **implemented today**.

### Semantics

- `case_insensitive` — case-insensitive matching
- `multiline` — `^` and `$` operate on line boundaries
- `dot_all` — `.` matches newlines
- `extended` — insignificant whitespace is skipped by the lexer in top-level extended mode
- `unicode` — enables Unicode-sensitive behavior currently used by parts of text policy and selected escapes

### Important note on `unicode`

`unicode` is **not** documented as a generic “all Unicode semantics enabled everywhere” switch.

What it currently affects includes:

- Unicode-aware word-boundary policy (`\b`, `\B` via `text_policy`)
- Unicode-aware `\d` / `\D`
- compatibility with pattern-level `(*UCP)` / `(*UTF)` verbs, which currently set the same internal Unicode flag

Do **not** assume every escape or class becomes Unicode-aware just because `.unicode = true`.

---

## Stable external flag-string contract

This project now exposes **two intentional flag parsers** for two different jobs:

1. `common.CompileFlags.parse(flags_str)`
   - native engine-facing parser
   - preserves direct engine semantics
   - `u` sets `.unicode = true`

2. `common.MongoExternalOptions.parse(flags_str)`
   - Mongo-compatible external `$options` parser for wrapper/integration layers
   - canonicalizes flags for caching and transport-level equality
   - accepts Mongo `u` but normalizes it away as redundant

### `common.MongoExternalOptions.parse(flags_str)`

For integrations that accept an external option string (for example Mongo-style `$options` or SQLite helper wrappers), the supported external flag alphabet is:

- `i`
- `m`
- `s`
- `x`
- `u`

### External flag rules

- **Supported flags:** exactly `imsxu`
- **Unknown flags:** hard error
- **Order:** irrelevant
- **Duplicates:** allowed and semantically ignored
- **Mongo `u`:** accepted but treated as a redundant no-op by the Mongo parser

Examples:

- `"im"` and `"mi"` are equivalent
- `"ii"` is valid and equivalent to `"i"`
- `"u"` is valid and canonicalizes to the empty canonical option string
- `"g"` is invalid
- `"y"` is invalid

### Canonicalization

`MongoExternalOptions.parse(...)` produces:

- `compile_flags` — the engine flags actually used for Mongo wrapper compilation
- `canonicalSlice()` — a canonical cache-key-friendly representation using stable `i`, `m`, `s`, `x` order with redundant `u` removed

That means semantically equivalent Mongo option strings share the same cache identity:

- `"im"`
- `"mi"`
- `"iim"`
- `"uim"`

all canonicalize to the same effective option set.

### Why this matters

Wrapper layers should rely on this documented contract, **not** on incidental regex parser behavior.

The wrapper should own only:

- flag-string validation/canonicalization
- cache key normalization
- transport-specific error mapping

The engine owns:

- regex syntax
- inline modifiers like `(?i)`
- PCRE verbs like `(*UTF)` / `(*UCP)`
- Unicode properties like `\p{Latin}`
- lookaround, recursion, backreferences, and other pattern semantics

---

## MongoDB-compatible wrapper contract

MongoDB documents `$options` with support for:

- `i`
- `m`
- `s`
- `x`
- `u`

MongoDB also documents `u` as **accepted but redundant because UTF is enabled by default**.

### Current project status versus MongoDB

The Mongo wrapper contract now follows that external-option rule explicitly:

- `u` is accepted
- `u` is redundant in the Mongo wrapper parse path
- unknown flags are hard errors
- duplicates are ignored
- order is irrelevant
- cache identity is based on canonicalized Mongo options, not raw input order

This behavior is implemented through `common.MongoExternalOptions.parse(...)` and consumed by the SQLite/BSON wrapper path.

### Recommended wrapper policy

If your wrapper exposes a Mongo-style `flags` / `$options` string, the public contract is:

1. Accept only `imsxu`
2. Reject unknown options explicitly
3. Canonicalize duplicates and order before caching
4. Treat Mongo `u` as accepted but redundant
5. Preserve regex pattern semantics as engine-owned

### Important boundary

This does **not** mean the native engine-facing `CompileFlags.parse(...)` path changed meaning.

- native `CompileFlags.parse("u")` still enables the engine's internal `.unicode` flag
- Mongo wrapper entrypoints should use `MongoExternalOptions.parse(...)`
- direct engine users should choose the parser that matches their intended contract

---

## Pattern-language ownership

The following are **engine-owned**, not wrapper-owned:

- inline modifiers: `(?i)`, `(?m)`, `(?s)`, `(?x)`, `(?-i)`
- PCRE verbs: `(*UTF)`, `(*UCP)`
- Unicode properties: `\p{...}`, `\P{...}`
- lookahead/lookbehind
- recursion and subroutines
- backreferences and named captures
- grapheme matching `\X`
- anchor semantics such as `\A`, `\z`, `\Z`

If an integration layer tries to parse or reinterpret these features independently, that is outside the intended architecture.

---

## Input validity guarantees

### Patterns

Patterns containing an internal null byte are invalid.

### External flag strings

External flag strings containing an internal null byte are invalid.

### Unknown external flags

Unknown external flags are invalid.

---

## Error model

Public callers should assume the following high-level error categories may occur:

- invalid pattern
- invalid flags
- invalid UTF-8 (where strict validation is required by the selected execution policy)
- unsupported or not-yet-implemented regex feature
- timeout / backtracking abort protection
- allocation failure

Do not write logic that depends on undocumented internal parser error distinctions unless you control both ends of the integration.

---

## Mongo-compatibility: honest status

This repository is reasonably described as **Mongo-compatible in many important regex behaviors**, especially around:

- PCRE-like syntax support
- inline modifiers
- Unicode properties and selected PCRE verbs
- advanced constructs used in Mongo-derived edge cases
- explicit erroring on invalid external flags

However, if you want to claim strict Mongo parity for regex options and semantics, keep these gaps in mind:

1. **Mongo-compatible external `u` now behaves as a redundant no-op only in the Mongo wrapper parse path**
   - the native engine-facing `CompileFlags.parse("u")` path still intentionally enables `.unicode`
2. **Unicode-mode behavior is still partial rather than globally uniform once inside engine semantics**
   - for example `\d`/word boundaries are Unicode-sensitive under native `.unicode`, while other escapes are not clearly switched the same way
3. **Some PCRE features remain intentionally unsupported or not implemented**
   - e.g. script runs `(*sr:)`
   - `(*BSR_UNICODE)`
   - unsupported PCRE verbs such as `(*FAIL)`, `(*ACCEPT)`, `(*COMMIT)`
4. **Companion wrapper behavior is not yet packaged and versioned as a first-class public API surface**
5. **Documentation must be kept aligned with code and tests**
   - stale docs are compatibility debt

---

## What would be needed to claim stronger Mongo compatibility

To make the “mongo-compat” claim crisper and easier to defend publicly, the codebase should continue with the following:

1. **Keep the split boundary explicit**
   - Mongo wrapper entrypoints use `MongoExternalOptions.parse(...)`
   - native engine callers use `CompileFlags.parse(...)` or typed `CompileFlags`

2. **Audit Unicode-sensitive escapes/classes for consistency under Mongo expectations**
   - especially `\w`, `\W`, and other classes if Mongo/PCRE/UCP expectations are part of the claim

3. **Document wrapper/public API separately from internal engine APIs**
   - the Zig module API and the SQLite/BSON helper contract should each have a stable document

4. **Keep unsupported features explicitly listed**
   - so “mongo-compat” never silently implies full PCRE2 parity

5. **Add integration coverage for canonical Mongo option handling**
   - e.g. `"mi" == "im"`
   - duplicate options reuse the same semantics
   - `u` matches the same as no options in Mongo wrapper mode

---

## Minimal examples

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

### Top-level flags

```zig
const std = @import("std");
const regex = @import("regex");

test "top-level flags" {
    const allocator = std.testing.allocator;

    var re = try regex.Regex.compileWithFlags(allocator, "^a.b$", .{
        .case_insensitive = true,
        .multiline = true,
        .dot_all = true,
    });
    defer re.deinit();

    try std.testing.expect(try re.isMatch("A\nB"));
}
```

### External flag parsing

```zig
const std = @import("std");
const regex = @import("regex");

test "external flags contract" {
    const flags = try regex.common.CompileFlags.parse("imsu");
    try std.testing.expect(flags.case_insensitive);
    try std.testing.expect(flags.multiline);
    try std.testing.expect(flags.dot_all);
    try std.testing.expect(flags.unicode);
    try std.testing.expectError(error.InvalidFlags, regex.common.CompileFlags.parse("g"));
}
```

---

## Source of truth

When this document and other prose disagree:

1. `src/root.zig` defines the exported Zig module surface
2. `src/common.zig` defines the external top-level flag parser contract
3. engine behavior in `src/parser.zig`, `src/regex.zig`, `src/text_policy.zig`, and matching engines defines actual regex semantics
4. integration wrappers should document only the subset they intentionally expose

---

**Last updated:** 2026-03-30
