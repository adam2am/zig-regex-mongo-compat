# zig-regex-mongo-compat

<div align="center">

**MongoDB PCRE2-compatible regex engine for Zig**

[![Zig](https://img.shields.io/badge/Zig-0.15.2-orange.svg)](https://ziglang.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-631%2F631%20passing-green.svg)](test/)

[Features](#features) - [Installation](#installation) - [Quick Start](#quick-start) - [Test Results](#test-results) - [Documentation](#documentation)

</div>

---

## Overview

zig-regex-mongo-compat is a fork of [zig-regex](https://github.com/zig-utils/zig-regex) extended with MongoDB PCRE2 compatibility features. It adds Unicode script properties (`\\p{Latin}`, `\\p{Greek}`, etc.), literal sequences (`\\Q...\\E`), PCRE flags (`(*UTF)`, `(*UCP)`), recursion/subroutine support, PCRE2 10.47-style recursion/subroutine capture return lists (`(?R(grouplist))`, `(?n(grouplist))`, `(?&name(grouplist))`), relative/absolute/named `\\g{...}` backreferences, advanced edge-case handling, and MongoDB-oriented behavior for regex operations.

The current architecture uses a **bytecode VM** as the primary engine for the regular-safe subset and an **optimized backtracking engine** for advanced PCRE-compatible constructs such as lookaround, recursion, backreferences, conditionals, atomic groups, and extended grapheme matching. Shared execution planning and text-policy layers keep input validation, Unicode boundary behavior, and engine routing explicit and centralized.

**Current Status:** v0.7.0 - 631/631 Zig tests passing (100%)

## Features

### Core Regex Features

| Feature | Syntax | Status |
|---------|--------|--------|
| **Literals** | `abc`, `123` | ✅ Stable |
| **Quantifiers** | `*`, `+`, `?`, `{n}`, `{m,n}` | ✅ Stable |
| **Lazy Quantifiers** | `*?`, `+?`, `??` | ✅ Stable |
| **Alternation** | `a\|b\|c` | ✅ Stable |
| **Character Classes** | `\d`, `\w`, `\s`, `\D`, `\W`, `\S` | ✅ Stable |
| **Custom Classes** | `[abc]`, `[a-z]`, `[^0-9]` | ✅ Stable |
| **Anchors** | `^`, `$`, `\b`, `\B` | ✅ Stable |
| **Wildcards** | `.` | ✅ Stable |
| **Capturing Groups** | `(...)` | ✅ Stable |
| **Named Groups** | `(?<name>...)` | ✅ Stable |
| **Non-capturing** | `(?:...)` | ✅ Stable |
| **Lookahead** | `(?=...)`, `(?!...)` | ✅ Stable |
| **Lookbehind** | `(?<=...)`, `(?<!...)` | ✅ Stable |
| **Backreferences** | `\1`, `\2` | ✅ Stable |
| **Literal Sequences** | `\Q...\E` | ✅ Stable |
| **Inline Modifiers** | `(?i)`, `(?m)`, `(?s)`, `(?x)`, `(?-i)` | ✅ Stable |
| **Scoped Modifiers** | `(?i:...)` | ✅ Stable |
| **Case-insensitive** | Flag `i` | ✅ Stable |
| **Multiline** | Flag `m` | ✅ Stable |
| **Dot-all** | Flag `s` | ✅ Stable |
| **Extended** | Flag `x` | ✅ Stable |
| **Escaping** | `\\`, `\.`, `\n`, `\t`, `\r` | ✅ Stable |

### Unicode Support

| Feature | Syntax | Status |
|---------|--------|--------|
| **Unicode Scripts** | `\p{Latin}`, `\p{Greek}`, `\p{Cyrillic}` | ✅ Stable |
| | `\p{Arabic}`, `\p{Hebrew}` | ✅ Stable |
| | `\p{Han}`, `\p{Hiragana}`, `\p{Katakana}` | ✅ Stable |
| **Additional script properties** | e.g. `\p{Hangul}` | ➖ Not implemented yet |
| **PCRE Flags** | `(*UTF)`, `(*UCP)` | ✅ Stable |
| **Unicode \b** | `(*UCP)` with `\b` | ✅ Stable |
| **Unicode \w** | `(*UCP)` with `\w` | ✅ Stable |
| **Unicode \d** | `(*UCP)` with `\d` | ✅ Stable |
| **POSIX Classes** | `[:alpha:]`, `[:digit:]` | ✅ Stable |
| **\h, \v** | Horizontal/vertical whitespace | ✅ Stable |
| **\R** | Any newline sequence | ✅ Stable |
| **\p{Any}** | Match any character | ✅ Stable |
| **\X** | Extended grapheme cluster | ✅ Stable |

### Advanced PCRE Features

| Feature | Status | Notes |
|---------|--------|-------|
| **Possessive Quantifiers** | ✅ Stable | `*+`, `++`, `?+`, `{n,m}+` |
| **Atomic Groups** | ✅ Stable | `(?>...)` |
| **Conditional Patterns** | ✅ Stable | `(?(1)yes\|no)` |
| **Recursive Patterns** | ✅ Stable | `(?R)`, `(?0)`, `(?1)`-`(?9)`, forward refs, depth limit |
| **Extended Backreferences** | ✅ Stable | `\g{-1}`, `\g{+1}`, `\g{1}`, `\g{name}` |
| **Branch Reset** | ✅ Stable | `(?\|...)` |
| **Script Runs** | ❌ Not implemented | `(*sr:)` |
| **BSR Unicode** | ❌ Not implemented | `(*BSR_UNICODE)` |
| **PCRE Verbs** | ❌ Not supported | `(*FAIL)`, `(*ACCEPT)`, `(*COMMIT)` |

### Advanced Features

- **Hybrid Execution Engine**: Automatically selects between a bytecode VM and optimized backtracking
- **Bytecode VM Core**: Flat instruction stream for fast matching on the regular-safe subset
- **Shared Execution Planning**: Centralized engine routing, validation policy, and boundary policy selection
- **Shared Text Policy**: One source of truth for UTF-8 validation, line breaks, and ASCII vs UCP word boundaries
- **O(1) Character Matching**: FastBitSet (256-bit) provides constant-time ASCII/Latin-1 character class lookups
- **AST Optimization**: Constant folding, dead code elimination, quantifier simplification
- **Pattern Macros**: Composable, reusable pattern definitions
- **Type-Safe Builder API**: Fluent interface for programmatic pattern construction
- **Thread Safety**: Safe concurrent matching with `SharedRegex` and `RegexCache`
- **Pattern Analysis**: Built-in ReDoS detection and pattern linting
- **ReDoS Protection**: Hard-abort flag prevents catastrophic backtracking loops
- **Comprehensive API**: `compile`, `find`, `findAll`, `replace`, `replaceAll`, `split`, iterator support

### Quality

- **Zero Dependencies**: Only Zig standard library
- **Fast Primary Engine**: Bytecode VM executes the regular-safe subset with low overhead and contiguous instruction dispatch
- **Memory Safety**: Full control via Zig allocators, no hidden allocations, zero leaks
- **O(1) Character Matching**: FastBitSet provides 256-bit lookup for ASCII/Latin-1 characters
- **ReDoS Protection**: Planning + hard-abort protection prevent catastrophic backtracking from taking down matching
- **631 Zig Tests**: 631/631 passing (100%) - native low-level coverage across anchors (`\\A`, `\\z`, `\\Z`), recursion, backreferences, Unicode, atomic groups, graphemes, parser/compiler hardening, and Unicode-aware word-class semantics
- **304 Companion Integration Tests**: Verified in the `bson_helpers` SQLite wrapper suite, covering BSON path extraction, wrapper cache isolation, error propagation, and MongoDB-style end-to-end PCRE edge cases
- **Production Ready**: Core features stable, implemented Unicode/script support well-covered, and known limitations documented

## Installation

### Manual Installation

```bash
git clone https://github.com/yourusername/zig-regex-mongo-compat.git
cd zig-regex-mongo-compat
zig build test
```

### As a Dependency

This library is designed to be used as a dependency in other projects (e.g., SQLite extensions). See the `bson_helpers` project for integration example.

## Quick Start

### Basic Pattern Matching

```zig
const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "\\d{3}-\\d{4}");
    defer regex.deinit();

    if (try regex.find("Call me at 555-1234")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);
        std.debug.print("Found: {s}\n", .{match.slice}); // "555-1234"
    }
}
```

### Find All Matches

```zig
var regex = try Regex.compile(allocator, "\\d+");
defer regex.deinit();

const matches = try regex.findAll(allocator, "a1b23c456");
defer {
    for (matches) |*m| {
        var mut_m = m;
        mut_m.deinit(allocator);
    }
    allocator.free(matches);
}

// matches: "1", "23", "456"
```

### Replace

```zig
var regex = try Regex.compile(allocator, "(\\w+)@(\\w+)");
defer regex.deinit();

const result = try regex.replace(allocator, "email: user@host ok", "[$0]");
defer allocator.free(result);
// result: "email: [user@host] ok"
```

### Capture Groups

```zig
var regex = try Regex.compile(allocator, "(\\d{4})-(\\d{2})-(\\d{2})");
defer regex.deinit();

if (try regex.find("Date: 2024-03-15")) |match| {
    var mut_match = match;
    defer mut_match.deinit(allocator);

    // match.captures[0] = "2024"
    // match.captures[1] = "03"
    // match.captures[2] = "15"
}
```

### Case-Insensitive / Multiline

```zig
var regex = try Regex.compileWithFlags(allocator, "^hello", .{
    .case_insensitive = true,
    .multiline = true,
});
defer regex.deinit();
```


## Building

```bash
zig build                              # Build library
zig build test                         # Run all Zig tests
zig build test-unicode-property        # Run Unicode property tests
zig build test-string-anchors          # Run \\A / \\z / \\Z anchor tests

# Full test suite (requires bson_helpers project)
cd ../bson_helpers
bun run build && bun test/ts/test_edge_cases.ts
```

## Documentation

- [Unsupported Features Analysis](UNSUPPORTED_FEATURES.md) - Detailed breakdown of missing features and implementation roadmap

## Test Results

**Overall (library repo):** 631/631 Zig tests passing (100%)

**Companion wrapper verification:** 304/304 `bson_helpers` TS integration tests passing (end-to-end SQLite extension coverage)

### ✅ Fully Working
- Core regex features (anchors, quantifiers, character classes, groups)
- Unicode support for the currently implemented script properties (Latin, Greek, Cyrillic, Arabic, Hebrew, Han, Hiragana, Katakana)
- Unicode-aware `\\w`, `\\W`, `\\b`, and `\\B` under `(*UCP)` or top-level `.unicode = true`
- Literal and `(*UCP)` boundary coverage for additional non-ASCII text such as Hangul/Korean
- PCRE flags (`(*UTF)`, `(*UCP)`)
- Lookahead/lookbehind (positive and negative)
- Backreferences and named groups
- Inline modifiers (`(?i)`, `(?m)`, `(?s)`, `(?x)`, `(?-i)`)
- Literal sequences (`\Q...\E`)
- ReDoS protection (nested quantifiers, alternation overlap)
- Edge cases (empty patterns, deep nesting, null handling)
- **NEW: Possessive quantifiers** `*+`, `++`, `?+`, `{n,m}+`
- **NEW: Atomic groups** `(?>...)`
- **NEW: Conditional patterns** `(?(1)yes|no)`
- **NEW: Branch reset groups** `(?|...)`
- **NEW: Horizontal/vertical whitespace** `\h`, `\v`
- **NEW: Any newline** `\R`
- **NEW: Unicode property** `\p{Any}`
- **NEW: Extended grapheme clusters** `\X` (UAX#29 compliant)
- **NEW: Recursive patterns** `(?R)`, `(?0)`, `(?1)`-`(?9)` with depth limit

### ⚠️ Known Issues
- No currently known correctness regressions in the covered feature set
- Unsupported and partially implemented PCRE features are explicitly tested and documented below

### ? Not Implemented (2 tests)
- Script runs `(*sr:)`
- `(*BSR_UNICODE)` flag

### 🚫 Intentionally Unsupported (4 tests)
- PCRE verbs: `(*FAIL)`, `(*ACCEPT)`, `(*COMMIT)` (return errors as expected)
- Invalid flags like `g` (return errors as expected)
- Null bytes in patterns (return errors as expected)

See [UNSUPPORTED_FEATURES.md](UNSUPPORTED_FEATURES.md) for detailed analysis and implementation roadmap.

## Requirements

- Zig 0.15.2 or later
- No external dependencies

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass (`zig build test`)
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Acknowledgments

- **Forked from:** [zig-regex](https://github.com/zig-utils/zig-regex) by zig-utils
- **Inspired by:** Ken Thompson's automata ideas, RE2 (Google's regex engine), PCRE2 semantics, and Rust's regex ecosystem
- **MongoDB PCRE2 compatibility:** Test cases derived from MongoDB's regex implementation

## Roadmap

### v0.7.0
- [x] FastBitSet for O(1) ASCII matching
- [x] Recursive patterns `(?R)`, `(?0)`, `(?1)`-`(?9)` with depth limit
- [x] ReDoS protection with hard-abort flag
- [x] PCRE2 10.47+ `(?R(grouplist))` / `(?n(grouplist))` capture return values from recursion/subroutines
- [x] Relative, absolute, and named backreferences `\g{-1}`, `\g{+1}`, `\g{1}`, `\g{name}`
- [x] Unicode-aware `\w` and `\W` under `(*UCP)` and top-level `.unicode`
- [ ] Script runs `(*sr:)`
- [ ] `(*BSR_UNICODE)` flag

### Future
- Continue expanding bytecode coverage for additional safe pattern subsets
- Further simplify backtracking candidate propagation internals

See [UNSUPPORTED_FEATURES.md](UNSUPPORTED_FEATURES.md) for detailed prioritization.
