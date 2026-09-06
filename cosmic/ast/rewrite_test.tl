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
