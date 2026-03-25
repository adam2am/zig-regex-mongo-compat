# zig-regex-mongo-compat

<div align="center">

**MongoDB PCRE2-compatible regex engine for Zig**

[![Zig](https://img.shields.io/badge/Zig-0.15.2-orange.svg)](https://ziglang.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-120%2F125%20passing-green.svg)](test/)

[Features](#features) - [Installation](#installation) - [Quick Start](#quick-start) - [Test Results](#test-results) - [Documentation](#documentation)

</div>

---

## Overview

zig-regex-mongo-compat is a fork of [zig-regex](https://github.com/zig-utils/zig-regex) extended with MongoDB PCRE2 compatibility features. Adds Unicode script properties (`\p{Latin}`, `\p{Greek}`, etc.), literal sequences (`\Q...\E`), PCRE flags (`(*UTF)`, `(*UCP)`), and comprehensive edge case handling for MongoDB regex operations.

Features Thompson NFA construction with linear time complexity, backtracking engine for advanced features, and extensive Unicode support. Built with zero external dependencies and full memory control through Zig allocators.

**Current Status:** v0.4.0 - 120/125 tests passing (96%)

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
| **PCRE Flags** | `(*UTF)`, `(*UCP)` | ✅ Stable |
| **Unicode \b** | `(*UCP)` with `\b` | ✅ Stable |
| **Unicode \w** | `(*UCP)` with `\w` | ✅ Stable |
| **Unicode \d** | `(*UCP)` with `\d` | ✅ Stable |
| **POSIX Classes** | `[:alpha:]`, `[:digit:]` | ✅ Stable |
| **\h, \v** | Horizontal/vertical whitespace | ✅ Stable |
| **\R** | Any newline sequence | ✅ Stable |
| **\p{Any}** | Match any character | ✅ Stable |
| **\X** | Extended grapheme cluster | ❌ Not implemented |

### Advanced PCRE Features

| Feature | Status | Notes |
|---------|--------|-------|
| **Possessive Quantifiers** | ✅ Stable | `*+`, `++`, `?+`, `{n,m}+` |
| **Atomic Groups** | ✅ Stable | `(?>...)` |
| **Conditional Patterns** | ✅ Stable | `(?(1)yes\|no)` |
| **Recursive Patterns** | ❌ Not implemented | `(?R)` |
| **Relative Backrefs** | ❌ Not implemented | `\g{-1}` |
| **Branch Reset** | ✅ Stable | `(?\|...)` |
| **Script Runs** | ❌ Not implemented | `(*sr:)` |
| **BSR Unicode** | ❌ Not implemented | `(*BSR_UNICODE)` |
| **PCRE Verbs** | ❌ Not supported | `(*FAIL)`, `(*ACCEPT)`, `(*COMMIT)` |

### Advanced Features

- **Hybrid Execution Engine**: Automatically selects between Thompson NFA (O(n*m)) and optimized backtracking
- **AST Optimization**: Constant folding, dead code elimination, quantifier simplification
- **NFA Optimization**: Epsilon transition removal, state merging, transition optimization
- **Pattern Macros**: Composable, reusable pattern definitions
- **Type-Safe Builder API**: Fluent interface for programmatic pattern construction
- **Thread Safety**: Safe concurrent matching with `SharedRegex` and `RegexCache`
- **Pattern Analysis**: Built-in ReDoS detection and pattern linting
- **Comprehensive API**: `compile`, `find`, `findAll`, `replace`, `replaceAll`, `split`, iterator support

### Quality

- **Zero Dependencies**: Only Zig standard library
- **Linear Time Matching**: Thompson NFA guarantees O(n*m) worst-case
- **Memory Safety**: Full control via Zig allocators, no hidden allocations, zero leaks
- **125 Test Suite**: 120/125 tests passing (96%) - comprehensive MongoDB PCRE2 edge case coverage
- **Production Ready**: Core features stable, Unicode support complete, known limitations documented

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
zig build test-literal-sequence        # Run \Q...\E tests

# Full test suite (requires bson_helpers project)
cd ../bson_helpers
bun run build && bun test/ts/test_edge_cases.ts
```

## Documentation

- [Unsupported Features Analysis](UNSUPPORTED_FEATURES.md) - Detailed breakdown of missing features and implementation roadmap

## Test Results

**Overall:** 121/126 tests passing (96%)

### ✅ Fully Working (114 tests)
- Core regex features (anchors, quantifiers, character classes, groups)
- Unicode support (8 scripts: Latin, Greek, Cyrillic, Arabic, Hebrew, Han, Hiragana, Katakana)
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

### ⚠️ Known Issues (0 tests)
- None

### ❌ Not Implemented (4 tests)
- `\X` (extended grapheme cluster)
- Recursive patterns `(?R)`
- Relative backreferences `\g{-1}`
- Script runs `(*sr:)`
- `(*BSR_UNICODE)` flag

### 🚫 Intentionally Unsupported (6 tests)
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
- **Inspired by:** Ken Thompson's NFA construction algorithm, RE2 (Google's regex engine), Rust's regex crate
- **MongoDB PCRE2 compatibility:** Test cases derived from MongoDB's regex implementation

## Roadmap

### Next Release (v0.4.1)
- Fix possessive quantifier bug (`*+`, `++`)
- Implement `\X` (extended grapheme cluster)
- Implement atomic groups `(?>...)`

### Future
- Script runs `(*sr:)`
- Relative backreferences `\g{-1}`
- Recursive patterns `(?R)`
- `(*BSR_UNICODE)` flag

See [UNSUPPORTED_FEATURES.md](UNSUPPORTED_FEATURES.md) for detailed prioritization.
