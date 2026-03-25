# Regex Features Implementation Roadmap

**Project:** zig-regex-mongo-compat  
**Status:** 🚧 In Progress  
**Current:** 472/472 tests passing (100%)

---

## 📋 Features to Implement (Ranked by Difficulty)

| # | Feature | Complexity | Effort | Status |
|---|---------|-----------|--------|--------|
| 1 | `(?|...)` Branch Reset Groups | LOW | 4-8h | ✅ Complete |
| 2 | `(?(1)yes|no)` Conditional Patterns | MEDIUM | 1-2d | ✅ Complete |
| 3 | `\X` Extended Grapheme Clusters | MEDIUM-HIGH | 2-4d | ⬜ Not Started |
| 4 | `(?R)` Recursive Patterns | HIGH | 4-7d | ⬜ Not Started |

---

## 1️⃣ Branch Reset Groups `(?|...)`

**Priority:** 🟢 Quick Win  
**Complexity:** LOW  
**Estimated Effort:** 4-8 hours  
**Status:** ✅ Complete

### ✅ Implementation Complete

**Commit:** `0d2cc31`  
**Tests:** 481/481 passing (100%)  
**Files Modified:** 4 files, 783 insertions

**What was implemented:**
- Added `reset_stack` to Parser struct (follows `flag_stack` pattern)
- Implemented `parseAlternationWithReset()` function
- Detect `(?|` syntax and reset `capture_count` at each `|`
- 9 comprehensive tests covering all cases

**Architecture:**
- Stack-based state management
- Separate function for reset behavior
- Zero impact on existing code
- Handles nesting perfectly via stack

---

## 2️⃣ Conditional Patterns `(?(condition)yes|no)`

**Priority:** 🟡 Medium  
**Complexity:** MEDIUM  
**Estimated Effort:** 1-2 days  
**Status:** ✅ Complete

### 📖 Specification

**Syntax:** `(?| alternative1 | alternative2 | alternative3 )`

**Behavior:** Inside a branch reset group, capture group numbers are reset at the start of each alternative. This allows alternatives to share the same capture group numbers.

**Example:**
```regex
(a) (?| x(y)z | (p(q)r) | (t)u(v) ) (z)
```
- Group 1: `a`
- Group 2: `y` OR `p` OR `t` (depending on which alternative matched)
- Group 3: (none) OR `q` OR `v`
- Group 4: `z`

### 🎯 Implementation Checklist

#### Phase 1: Parser Changes
- [ ] Add `NSF_RESET` flag to nest structure
- [ ] Add `reset_group` field to nest structure (stores group count at `(?|` entry)
- [ ] Detect `(?|` syntax in parser
- [ ] On `(?|`: Save current `bracount` to `nest.reset_group`, set `NSF_RESET` flag
- [ ] On `|` inside `(?|`: Reset `bracount` to `nest.reset_group`
- [ ] On `)` closing `(?|`: `bracount` naturally holds max from all alternatives
- [ ] Handle nested `(?|` groups correctly

**Files to modify:**
- `src/parser.zig` (~30 lines)

#### Phase 2: Testing [use_workflow:zig-test-1rm1q5n]

**Happy Paths:**
- [ ] Test: `(?|a(b)|c(d))` matches "ab" → group 1 = "b"
- [ ] Test: `(?|a(b)|c(d))` matches "cd" → group 1 = "d"
- [ ] Test: `(x)(?|(a)(b)|(c)(d))(y)` → groups 1,2,3,4 numbered correctly
- [ ] Test: Nested branch reset `(?|(?|a(b)|c(d))|e(f))`
- [ ] Test: Backreference inside branch reset `(?|(a)\1|(b)\1)`
- [ ] Test: Named groups inside branch reset

**Unhappy Paths:**
- [ ] Test: Unclosed `(?|` → parse error
- [ ] Test: `(?|` without alternatives → parse error
- [ ] Test: Empty alternatives `(?||)` → valid (matches empty)

**Edge Cases:**
- [ ] Test: Branch reset at pattern start `(?|a|b)`
- [ ] Test: Branch reset at pattern end `x(?|a|b)`
- [ ] Test: Multiple branch resets `(?|a|b)(?|c|d)`
- [ ] Test: Branch reset with quantifiers `(?|a|b)+`

#### Phase 3: Verification
- [ ] Run full test suite: `zig build test --summary all`
- [ ] Verify no regressions (472+ tests passing)
- [ ] Add inline tests to `src/parser.zig` if needed
- [ ] Update test expectations in `test/ts/test_edge_cases.ts`

#### Phase 4: Documentation
- [ ] Add examples to parser comments
- [ ] Update HANDOFF.md with implementation notes
- [ ] Mark feature as ✅ Complete in this roadmap

---

## 2️⃣ Conditional Patterns `(?(condition)yes|no)`

**Priority:** 🟡 Medium  
**Complexity:** MEDIUM  
**Estimated Effort:** 1-2 days  
**Status:** ⬜ Not Started

### 📖 Specification

**Syntax:** `(?(condition)yes-pattern|no-pattern)` or `(?(condition)yes-pattern)`

**Condition Types:**
1. `(?(1)...)` — Test if group 1 captured
2. `(?(<name>)...)` — Test if named group captured
3. `(?(R)...)` — Test if currently in recursion
4. `(?(R1)...)` — Test if recursing into group 1
5. `(?(?=...)...)` — Positive lookahead as condition
6. `(?(?!...)...)` — Negative lookahead as condition
7. `(?(DEFINE)...)` — Define subroutines (always false)

**Example:**
```regex
^(a)?b(?(1)c|d)$
```
- Matches "abc" (group 1 captured, so 'c' required)
- Matches "bd" (group 1 not captured, so 'd' required)
- Does NOT match "ac" or "bc"

### 🎯 Implementation Checklist

#### Phase 1: AST & Parser Changes
- [ ] Add `ConditionalNode` to AST:
  ```zig
  conditional: struct {
      condition: ConditionType,
      yes_branch: *Node,
      no_branch: ?*Node,
  }
  ```
- [ ] Add `ConditionType` enum:
  ```zig
  enum {
      group_number: u16,
      group_name: []const u8,
      recursion_test,
      recursion_group: u16,
      assertion: *Node,  // lookahead/lookbehind
  }
  ```
- [ ] Parse `(?(` syntax
- [ ] Parse condition (number, name, R, R1, assertion)
- [ ] Parse yes-branch
- [ ] Parse optional `|` and no-branch
- [ ] Resolve group names/numbers at compile time

**Files to modify:**
- `src/ast.zig` (~20 lines)
- `src/parser.zig` (~100 lines)

#### Phase 2: Compiler Changes
- [ ] Add `OP_COND` / `OP_SCOND` opcodes
- [ ] Emit condition type + data (group number or offset)
- [ ] Emit yes-branch bytecode
- [ ] Emit `OP_ALT` if no-branch exists
- [ ] Emit no-branch bytecode
- [ ] Emit `OP_KET` to close conditional

**Files to modify:**
- `src/compiler.zig` (~80 lines)

#### Phase 3: Engine Changes
- [ ] Handle `OP_COND` in backtracking engine
- [ ] Evaluate condition:
  - Group number: Check if `captures[n]` is set
  - Group name: Resolve to number, check capture
  - Recursion test: Check `recursion_depth > 0`
  - Assertion: Execute lookahead/lookbehind
- [ ] Jump to yes-branch if condition true
- [ ] Jump to no-branch if condition false (or skip if no no-branch)

**Files to modify:**
- `src/backtrack.zig` (~60 lines)

#### Phase 4: Testing [use_workflow:zig-test-1rm1q5n]

**Happy Paths:**
- [ ] Test: `(a)?(?(1)b|c)` matches "ab" and "c"
- [ ] Test: `(a)?(?(1)b)` matches "ab" and "" (no no-branch)
- [ ] Test: `(?<name>a)?(?(name)b|c)` matches "ab" and "c"
- [ ] Test: `(?(?=a)a|b)` matches "a" (assertion condition)
- [ ] Test: `(?(R)a|b)` with recursion (requires feature #4)
- [ ] Test: Nested conditionals `(?(1)(?(2)a|b)|c)`

**Unhappy Paths:**
- [ ] Test: `(?(99)a|b)` → error (group doesn't exist)
- [ ] Test: `(?(<noname>)a|b)` → error (name doesn't exist)
- [ ] Test: `(?(a|b)` → parse error (unclosed)
- [ ] Test: `(?(1)` → parse error (missing yes-branch)

**Edge Cases:**
- [ ] Test: Forward reference `(?(2)a|b)(x)`
- [ ] Test: Empty branches `(?(1)||)`
- [ ] Test: Condition with quantifier `(?(1)a+|b*)`
- [ ] Test: Multiple conditions in sequence

#### Phase 5: Verification
- [ ] Run full test suite
- [ ] Verify no regressions
- [ ] Add inline tests to relevant files
- [ ] Update test expectations

#### Phase 6: Documentation
- [ ] Add examples to parser comments
- [ ] Document condition types
- [ ] Mark feature as ✅ Complete

---

## 3️⃣ Extended Grapheme Clusters `\X`

**Priority:** 🔴 Highest Value  
**Complexity:** MEDIUM-HIGH  
**Estimated Effort:** 2-4 days  
**Status:** ⬜ Not Started

### 📖 Specification

**Syntax:** `\X`

**Behavior:** Matches one extended grapheme cluster as defined by Unicode UAX#29. This is a "user-perceived character" which may consist of multiple codepoints.

**Examples:**
- `\X` matches "é" (single codepoint U+00E9)
- `\X` matches "é" (e + combining acute: U+0065 U+0301)
- `\X` matches "👨‍👩‍👧" (family emoji: man + ZWJ + woman + ZWJ + girl)
- `\X` matches "🇺🇸" (flag emoji: U+1F1FA + U+1F1F8)

### 🎯 Implementation Checklist

#### Phase 1: Unicode Data Generation
- [ ] Download Unicode 16.0 UCD files:
  - `DerivedCoreProperties.txt` (Grapheme_Cluster_Break property)
  - `GraphemeBreakTest.txt` (official test suite)
- [ ] Generate `ucp_gbtable` (16×16 bit matrix, 32 bytes):
  ```zig
  // Which property pairs allow continuation (1) vs break (0)
  const ucp_gbtable = [16]u16{
      0xFFFF,  // Control: breaks with everything
      0x0001,  // CR: continues only with LF
      // ... (see PCRE2 pcre2_ucd.c)
  };
  ```
- [ ] Generate `UCD_GRAPHBREAK` macro/function:
  ```zig
  fn UCD_GRAPHBREAK(c: u32) u8 {
      // Binary search or trie lookup in property table
      // Returns: gbControl, gbExtend, gbZWJ, gbRegional_Indicator, etc.
  }
  ```
- [ ] Add property table to `src/unicode_data.zig` (~150KB)

**Files to create/modify:**
- `src/unicode_data.zig` (new file, ~200 lines generated)
- `tools/generate_unicode_tables.zig` (new script)

#### Phase 2: Parser Changes
- [ ] Recognize `\X` escape sequence
- [ ] Emit `escape_X` token

**Files to modify:**
- `src/parser.zig` (~5 lines)

#### Phase 3: AST & Compiler Changes
- [ ] Add `extended_grapheme` to NodeType enum
- [ ] Add `OP_EXTUNI` opcode
- [ ] Emit `OP_EXTUNI` in compiler

**Files to modify:**
- `src/ast.zig` (~5 lines)
- `src/compiler.zig` (~10 lines)

#### Phase 4: Engine Implementation
- [ ] Implement `matchExtendedGrapheme` in backtracking engine:
  ```zig
  fn matchExtendedGrapheme(self: *BacktrackEngine, pos: usize) ?usize {
      if (pos >= self.subject.len) return null;
      
      var ptr = pos;
      const first = decodeUtf8(self.subject[ptr..]);
      var lgb = UCD_GRAPHBREAK(first.codepoint);
      ptr += first.len;
      
      var was_ep_ZWJ = false;
      
      while (ptr < self.subject.len) {
          const next = decodeUtf8(self.subject[ptr..]);
          const rgb = UCD_GRAPHBREAK(next.codepoint);
          
          // Check break table
          if ((ucp_gbtable[lgb] & (@as(u16, 1) << @intCast(rgb))) == 0) break;
          
          // Special case: Regional Indicators (even count rule)
          if (lgb == gbRegional_Indicator and rgb == gbRegional_Indicator) {
              const count = countPrecedingRIs(self.subject, ptr);
              if (count & 1 != 0) break;  // Odd count = break
          }
          
          // Special case: ZWJ + Extended Pictographic
          if (lgb == gbZWJ and rgb == gbExtended_Pictographic and !was_ep_ZWJ) {
              break;
          }
          
          was_ep_ZWJ = (lgb == gbExtended_Pictographic and rgb == gbZWJ);
          
          // Update state (except Extend after Extended_Pictographic)
          if (rgb != gbExtend or lgb != gbExtended_Pictographic) {
              lgb = rgb;
          }
          
          ptr += next.len;
      }
      
      return ptr;
  }
  ```
- [ ] Implement `countPrecedingRIs` helper (backward scan)
- [ ] Add `OP_EXTUNI` case to match loop

**Files to modify:**
- `src/backtrack.zig` (~160 lines)
- `src/common.zig` (~20 lines for helpers)

#### Phase 5: Optimizer Changes
- [ ] Treat `\X` like a single character for min/max length
- [ ] Add `extended_grapheme` cases to optimizer switches

**Files to modify:**
- `src/optimizer.zig` (~10 lines)
- `src/pattern_analyzer.zig` (~5 lines)

#### Phase 6: Testing [use_workflow:zig-test-1rm1q5n]

**Happy Paths:**
- [ ] Test: `\X` matches "a" (ASCII)
- [ ] Test: `\X` matches "é" (precomposed U+00E9)
- [ ] Test: `\X` matches "é" (decomposed e + combining acute)
- [ ] Test: `\X` matches "👨‍👩‍👧" (family emoji with ZWJ)
- [ ] Test: `\X` matches "🇺🇸" (flag emoji, 2 Regional Indicators)
- [ ] Test: `\X+` matches "café" as 4 graphemes
- [ ] Test: `\X{3}` matches exactly 3 graphemes
- [ ] Test: `^\X$` matches single grapheme only

**Unhappy Paths:**
- [ ] Test: `\X` at end of string → no match
- [ ] Test: `\X` with invalid UTF-8 → error or skip

**Edge Cases:**
- [ ] Test: Odd number of Regional Indicators (break between)
- [ ] Test: Even number of Regional Indicators (no break)
- [ ] Test: ZWJ without Extended Pictographic before it
- [ ] Test: Hangul syllables (L+V+T sequences)
- [ ] Test: Indic conjuncts (consonant + virama + consonant)
- [ ] Test: Emoji with skin tone modifiers
- [ ] Test: Multiple ZWJ sequences

**Official Test Suite:**
- [ ] Run Unicode GraphemeBreakTest.txt (1800+ test cases)
- [ ] Verify 100% pass rate

#### Phase 7: Verification
- [ ] Run full test suite
- [ ] Verify no regressions
- [ ] Performance test: `\X+` on large Unicode text
- [ ] Memory test: No leaks in property lookups

#### Phase 8: Documentation
- [ ] Document Unicode version (16.0)
- [ ] Add examples for emoji, combining marks, flags
- [ ] Note performance characteristics (RI backward scan)
- [ ] Mark feature as ✅ Complete

---

## 4️⃣ Recursive Patterns `(?R)`

**Priority:** 🟠 Advanced Feature  
**Complexity:** HIGH  
**Estimated Effort:** 4-7 days  
**Status:** ⬜ Not Started

### 📖 Specification

**Syntax:** 
- `(?R)` — Recurse into entire pattern
- `(?0)` — Same as `(?R)`
- `(?1)` — Recurse into group 1
- `(?&name)` — Recurse into named group

**Behavior:** Recursively match the pattern (or subpattern). Each recursion level is atomic in PCRE2 (cannot backtrack into it).

**Example:**
```regex
\((?:[^()]|(?R))*\)
```
Matches balanced parentheses:
- `()` ✓
- `(())` ✓
- `(()(()))` ✓
- `(()` ✗ (unbalanced)

### 🎯 Implementation Checklist

#### Phase 1: AST & Parser Changes
- [ ] Add `RecursionNode` to AST:
  ```zig
  recursion: struct {
      target: RecursionTarget,
  }
  
  const RecursionTarget = union(enum) {
      whole_pattern,
      group_number: u16,
      group_name: []const u8,
  };
  ```
- [ ] Parse `(?R)`, `(?0)`, `(?1)`, `(?&name)` syntax
- [ ] Resolve group names/numbers at compile time
- [ ] Handle forward references (group defined after recursion)

**Files to modify:**
- `src/ast.zig` (~20 lines)
- `src/parser.zig` (~50 lines)

#### Phase 2: Compiler Changes
- [ ] Add `OP_RECURSE` opcode
- [ ] Emit recursion target (offset to pattern start or group)
- [ ] Patch offsets after full compilation (for forward refs)

**Files to modify:**
- `src/compiler.zig` (~120 lines)

#### Phase 3: Engine Changes (CRITICAL)
- [ ] Add recursion stack structure:
  ```zig
  const RecursionFrame = struct {
      subject_position: usize,
      capture_offsets: []u32,  // Snapshot
      code_position: usize,    // Return address
      recursion_depth: u32,
  };
  
  var recursion_stack: std.ArrayList(RecursionFrame);
  ```
- [ ] Add `MAX_RECURSION` constant (default: 1000)
- [ ] Handle `OP_RECURSE` in match loop:
  1. Check depth limit
  2. Save current state (push frame)
  3. Jump to target pattern
  4. Execute recursively
  5. On success: pop frame, continue
  6. On failure: return NOMATCH (atomic, no backtrack)
- [ ] Implement state save/restore for captures
- [ ] Handle recursion depth counter

**Files to modify:**
- `src/backtrack.zig` (~300 lines)
- `src/common.zig` (~20 lines for RecursionFrame)

#### Phase 4: Optimizer Changes
- [ ] Detect infinite recursion patterns (e.g., `(?R)` alone)
- [ ] Mark recursive patterns for special handling
- [ ] Add recursion cases to optimizer switches

**Files to modify:**
- `src/optimizer.zig` (~50 lines)
- `src/pattern_analyzer.zig` (~10 lines)

#### Phase 5: Testing [use_workflow:zig-test-1rm1q5n]

**Happy Paths:**
- [ ] Test: `\((?:[^()]|(?R))*\)` matches "()" and "(())"
- [ ] Test: `a(?R)?b` matches "ab", "aabb", "aaabbb"
- [ ] Test: `(?<name>a(?&name)?b)` matches "ab", "aabb"
- [ ] Test: `(?1)(a(?R)?b)` matches "aabb", "aaabbb"
- [ ] Test: Deep recursion (100 levels)
- [ ] Test: Captures inside recursion

**Unhappy Paths:**
- [ ] Test: `(?R)` alone → infinite recursion error
- [ ] Test: Recursion depth > 1000 → error
- [ ] Test: `(?99)` → error (group doesn't exist)
- [ ] Test: `(?&noname)` → error (name doesn't exist)

**Edge Cases:**
- [ ] Test: Recursion at pattern start
- [ ] Test: Recursion at pattern end
- [ ] Test: Multiple recursions in sequence
- [ ] Test: Recursion with quantifiers `(?R)+`
- [ ] Test: Recursion with alternation `(?R|x)`
- [ ] Test: Nested recursion (recursion calling recursion)
- [ ] Test: Captures from inner recursion (should NOT persist)

**Stress Tests:**
- [ ] Test: 1000 levels of recursion (at limit)
- [ ] Test: 1001 levels → error
- [ ] Test: Pathological pattern `(?R)*` → detect and reject

#### Phase 6: Safety & Performance
- [ ] Add recursion depth limit configuration
- [ ] Add memory limit for recursion stack
- [ ] Optimize frame allocation (reuse frames)
- [ ] Add recursion detection in optimizer (reject `(?R)` alone)

#### Phase 7: Verification
- [ ] Run full test suite
- [ ] Verify no regressions
- [ ] Memory leak test (recursion frames freed)
- [ ] Performance test (deep recursion overhead)

#### Phase 8: Documentation
- [ ] Document recursion depth limit
- [ ] Document atomicity behavior (vs Perl)
- [ ] Add examples for balanced structures
- [ ] Warn about infinite recursion patterns
- [ ] Mark feature as ✅ Complete

---

## 🧪 Testing Strategy

### Test File Organization
- **Unit tests:** Inline tests in source files (`src/*.zig`)
- **Integration tests:** `tests/*.zig` files
- **Edge cases:** `tests/parser_compiler_edge_cases.zig`
- **External tests:** `test/ts/test_edge_cases.ts` (bson_helpers)

### Test Coverage Requirements
- ✅ Happy paths (feature works as expected)
- ✅ Unhappy paths (errors handled gracefully)
- ✅ Edge cases (boundary conditions)
- ✅ Stress tests (limits, performance)
- ✅ Regression tests (existing features still work)

### Using [use_workflow:zig-test-1rm1q5n]
When adding tests, follow the Zig test framework pattern:
1. Add inline tests to source files for private functions
2. Add external test files for public API
3. Use `zig build test --summary all` to run all tests
4. Ensure 100% pass rate before marking feature complete

---

## 📊 Progress Tracking

### Current Status
- ✅ **\R (any newline)** — Complete (472 tests passing)
- ✅ **\p{Any}** — Complete
- ✅ **Atomic groups (?>...)** — Complete
- ✅ **Optimizer bug fix** — Complete
- ✅ **Branch Reset** — Complete (481 tests passing)
- 🔄 **Conditionals** — In Progress
- ⬜ **\X Grapheme Clusters** — Not Started
- ⬜ **Recursion** — Not Started

### Milestones
- [x] **Milestone 1:** Branch Reset complete (4-8 hours) ✅
- [ ] **Milestone 2:** Conditionals complete (1-2 days) 🔄
- [ ] **Milestone 3:** \X Grapheme Clusters complete (2-4 days)
- [ ] **Milestone 4:** Recursion complete (4-7 days)

### Estimated Total Effort
- **Minimum:** 7.5 days (4h + 1d + 2d + 4d)
- **Maximum:** 14 days (8h + 2d + 4d + 7d)
- **Realistic:** ~10 days

---

## 🔗 References

### PCRE2 Source Code
- [pcre2_compile.c](https://github.com/PCRE2Project/pcre2/blob/master/src/pcre2_compile.c) — Parser & compiler
- [pcre2_match.c](https://github.com/PCRE2Project/pcre2/blob/master/src/pcre2_match.c) — Backtracking engine
- [pcre2_extuni.c](https://github.com/PCRE2Project/pcre2/blob/master/src/pcre2_extuni.c) — \X implementation
- [pcre2_ucd.c](https://github.com/PCRE2Project/pcre2/blob/master/src/pcre2_ucd.c) — Unicode tables

### Unicode Standards
- [UAX#29: Text Segmentation](https://www.unicode.org/reports/tr29/) — Grapheme cluster algorithm
- [GraphemeBreakTest.txt](https://www.unicode.org/Public/UCD/latest/ucd/auxiliary/GraphemeBreakTest.txt) — Official test suite

### Tutorials & Guides
- [RexEgg: Recursion](https://www.rexegg.com/regex-recursion.php)
- [Regular-Expressions.info: Branch Reset](https://www.regular-expressions.info/branchreset.html)
- [Regular-Expressions.info: Conditionals](https://www.regular-expressions.info/conditional.html)

---

## 📝 Notes

- **Atomicity:** PCRE2 makes recursion atomic (cannot backtrack into it). Perl allows backtracking. We follow PCRE2.
- **Unicode Version:** Using Unicode 16.0 for \X implementation.
- **Recursion Limit:** Default 1000 levels, configurable.
- **Testing:** Use official Unicode test suite for \X validation.
- **Performance:** Regional Indicator backward scan is O(n) worst case.

---

**Last Updated:** 2026-03-25  
**Next Review:** After each feature completion
