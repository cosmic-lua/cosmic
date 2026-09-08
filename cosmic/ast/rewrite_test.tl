#!/usr/bin/env cosmic
--- Correctness probes for `cosmic.ast.rewrite`: a clean splice that
--- needs the formatter's whitespace round-trip, and the comment-loss
--- refusal that leaves a hit unmodified rather than silently dropping
--- a comment sitting in the match's own connective tissue.
local check = require("cosmic.check")
local ast_match = require("cosmic.ast.match")
local node_mod = require("cosmic.ast.node")
local rewrite_mod = require("cosmic.ast.rewrite")

local type Node = node_mod.Node

-- Same helper as cosmic/ast/match_test.tl's, kept local to this file.
local function pattern_ok(pattern_src: string): Node
  return check.must(ast_match.compile_pattern(pattern_src))
end

--- A clean splice -- no comment anywhere near the match -- confirms the
--- formatter round-trip: the spliced text (`assert(os.execute(cmd))`,
--- with no space rules of its own applied) comes back correctly spaced
--- because `rewrite` pipes it through `cosmic.format.format` rather
--- than hand-preserving whitespace.
local function test_rewrite_applies_a_clean_splice_and_formats_it()
  local pattern = pattern_ok("os.execute($X)")
  local result, err = rewrite_mod.rewrite(
    "os.execute(cmd)\n", "clean.tl", pattern, "assert(os.execute($X))")
  assert(result, "rewrite failed: " .. tostring(err))
  check.equal(result.code, "assert(os.execute(cmd))\n")
  check.equal(#result.refused, 0)
end

--- One capture name that is a literal prefix of another's (`_X` inside
--- `_XS`, once desugared) must not corrupt the longer name's own
--- substitution: an unanchored `text:gsub(cname, ...)` over `_X` would
--- also hit the `_X` inside `_XS`, turning "xs" into "xS" -- whole-
--- identifier matching (`find_name`) is what keeps the two capture
--- names from colliding.
local function test_rewrite_does_not_corrupt_a_capture_name_that_is_a_prefix_of_another()
  local pattern = pattern_ok("return $X + $XS")
  local result, err = rewrite_mod.rewrite(
    "return x + xs\n", "prefix.tl", pattern, "return $XS - $X")
  assert(result, "rewrite failed: " .. tostring(err))
  check.equal(#result.refused, 0)
  check.equal(result.code, "return xs - x\n")
end

--- Two matches in one source: splicing must run back-to-front so the
--- first hit's byte offsets (computed once, up front) stay valid after
--- the second hit's splice runs -- front-to-back would shift them out
--- from under it, corrupting the first hit's replacement into a syntax
--- error.
local function test_rewrite_applies_both_hits_in_a_two_hit_source()
  local pattern = pattern_ok("os.execute($X)")
  local source = "os.execute(cmd1)\nos.execute(cmd2)\n"
  local result, err = rewrite_mod.rewrite(source, "two.tl", pattern, "assert(os.execute($X))")
  assert(result, "rewrite failed: " .. tostring(err))
  check.equal(#result.refused, 0)
  check.equal(result.code, "assert(os.execute(cmd1))\nassert(os.execute(cmd2))\n")
end

--- A comment sitting between the two captures -- in the gap the swapped
--- template doesn't cover -- is not carried forward by either capture's
--- own span, so the hit is refused: left byte-for-byte unmodified
--- (comment included) rather than silently mangled by the splice.
local function test_rewrite_refuses_a_hit_that_would_drop_a_comment()
  local pattern = pattern_ok("return $A + $B")
  local source = "return a --[[ keep this ]] + b\n"
  local result, err = rewrite_mod.rewrite(source, "refuse.tl", pattern, "return $B + $A")
  assert(result, "rewrite failed: " .. tostring(err))
  check.equal(#result.refused, 1)
  check.equal(result.refused[1].comments[1], "--[[ keep this ]]")
  check.equal(result.code, source)
end

--- An empty replacement against a call-statement hit removes the whole
--- STATEMENT -- `test_a()`'s own line entirely, not just its own byte
--- span spliced with "" -- so the deletion leaves no blank line behind
--- and both `run()` calls (the one call `$F:^test_()`'s predicate does
--- not match) survive untouched.
---
--- The deleted statement sits between two others, not first in the
--- file: a byte-span-only deletion (the node's own span, leaving its
--- line's newline and the next line's content behind) would leave a
--- STRAY BLANK LINE mid-file, and `cosmic.format.format`'s own
--- whitespace normalization does not remove a blank line already
--- separating two statements -- only a leading blank line at the top
--- of the file gets stripped that way. Deleting the hit first (nothing
--- ahead of it) would let the formatter's leading-blank-line trim
--- launder a byte-span deletion into the same output as a line-range
--- one, so this case cannot tell the two apart.
local function test_rewrite_deletes_a_call_statement_leaving_no_blank_line()
  local pattern = pattern_ok("$F:^test_()")
  local source = "run()\ntest_a()\nrun()\n"
  local result, err = rewrite_mod.rewrite(source, "delete.tl", pattern, "")
  assert(result, "rewrite failed: " .. tostring(err))
  check.equal(#result.refused, 0)
  check.equal(result.code, "run()\nrun()\n")
end

--- The same deletion, reused-refusal side: a comment trailing the
--- statement on its OWN line sits outside the call node's own byte
--- span but inside the whole-line range the deletion removes -- the
--- hit is refused, exactly as a comment inside a normal splice's own
--- span would be, rather than silently vanishing with the line.
local function test_rewrite_refuses_a_statement_deletion_that_would_drop_a_trailing_comment()
  local pattern = pattern_ok("$F:^test_()")
  local source = "test_a() -- keep this\nrun()\n"
  local result, err = rewrite_mod.rewrite(source, "refuse_delete.tl", pattern, "")
  assert(result, "rewrite failed: " .. tostring(err))
  check.equal(#result.refused, 1)
  check.equal(result.refused[1].comments[1], "-- keep this")
  check.equal(result.code, source)
end

local function test_rewrite_refuses_to_delete_a_call_inside_a_declaration()
  local result, err = rewrite_mod.rewrite(
    "local answer = f(1)\n", "declaration.tl", pattern_ok("f($X)"), "")
  assert(result, "rewrite failed: " .. tostring(err))
  check.equal(#result.refused, 1)
  check.equal(result.refused[1].reason, "matched call is not a statement")
  check.equal(result.code, "local answer = f(1)\n")
end

local function test_rewrite_deletes_only_one_statement_on_a_shared_line()
  local source = "before(); target(); after()\n"
  local result, err = rewrite_mod.rewrite(
    source, "shared_line.tl", pattern_ok("target()"), "")
  assert(result, "rewrite failed: " .. tostring(err))
  check.equal(#result.refused, 0)
  check.equal(result.code, "before(); after()\n")
end

local function test_rewrite_groups_a_captured_binary_expression()
  local result, err = rewrite_mod.rewrite(
    "return f(a + b)\n", "precedence.tl", pattern_ok("f($X)"), "$X * 2")
  assert(result, "rewrite failed: " .. tostring(err))
  check.equal(#result.refused, 0)
  check.equal(result.code, "return (a + b) * 2\n")
end

local function test_rewrite_leaves_placeholders_in_strings_and_comments_literal()
  local result, err = rewrite_mod.rewrite(
    "return f(value)\n", "literal.tl", pattern_ok("f($X)"),
    'g("$X", $X) -- $X')
  assert(result, "rewrite failed: " .. tostring(err))
  check.equal(#result.refused, 0)
  check.equal(result.code, 'return g("$X", value) -- $X\n')
end

local function test_rewrite_preserves_nonempty_and_empty_list_captures()
  local pattern = pattern_ok("f($$$XS)")
  local many, many_err = rewrite_mod.rewrite(
    "return f(a, b)\n", "list.tl", pattern, "g($$$XS)")
  assert(many, "rewrite failed: " .. tostring(many_err))
  check.equal(many.code, "return g(a, b)\n")
  local empty, empty_err = rewrite_mod.rewrite(
    "return f()\n", "empty_list.tl", pattern, "g($$$XS)")
  assert(empty, "rewrite failed: " .. tostring(empty_err))
  check.equal(empty.code, "return g()\n")
end

local function test_rewrite_refuses_overlapping_hits_atomically()
  local source = "return f(f(1))\n"
  local result, err = rewrite_mod.rewrite(
    source, "overlap.tl", pattern_ok("f($X)"), "g($X)")
  assert(result, "rewrite failed: " .. tostring(err))
  check.equal(#result.refused, 2)
  check.equal(result.refused[1].reason, "overlapping rewrite hits")
  check.equal(result.code, source)
end
