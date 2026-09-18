--- Correctness probes for `build.ast.rewrite`: a clean splice, and the
--- comment-loss refusal that leaves a hit unmodified rather than
--- silently dropping a comment sitting in the match's own connective
--- tissue.
---
--- cosmic (v1)'s own version of the first test below also checks that
--- the splice comes back correctly spaced through `cosmic.format`'s
--- whitespace round-trip; v2 has no `cosmic.format` yet (see
--- `rewrite.tl`'s own header comment), so this splice is verified
--- byte-exact against the raw spliced text instead -- every fixture
--- below is already well-formed, so the two checks agree regardless.
local teal = require("build.teal")
local ast = require("build.ast")
local ast_match = require("build.ast.match")
local node_mod = require("build.ast.node")
local rewrite_mod = require("build.ast.rewrite")

local type Node = node_mod.Node

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

-- Same helper as build/ast/match_test.tl's, kept local to this file.
local function pattern_ok(pattern_src: string): Node
  local pattern, err = ast_match.compile_pattern(built, pattern_src)
  assert(pattern ~= nil, "compile_pattern failed: " .. tostring(err))
  return pattern
end

--- A clean splice -- no comment anywhere near the match -- with a
--- replacement template (`assert(os.execute($X))`) that is already
--- correctly spaced, so the raw splice matches byte-for-byte.
local function test_rewrite_applies_a_clean_splice()
  local pattern = pattern_ok("os.execute($X)")
  local result, err = rewrite_mod.rewrite(
    built, "os.execute(cmd)\n", "clean.tl", pattern, "assert(os.execute($X))")
  assert(result ~= nil, "rewrite failed: " .. tostring(err))
  assert(result.code == "assert(os.execute(cmd))\n", "code: " .. result.code)
  assert(#result.refused == 0, "expected no refusals")
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
    built, "return x + xs\n", "prefix.tl", pattern, "return $XS - $X")
  assert(result ~= nil, "rewrite failed: " .. tostring(err))
  assert(#result.refused == 0, "expected no refusals")
  assert(result.code == "return xs - x\n", "code: " .. result.code)
end

--- Two matches in one source: splicing must run back-to-front so the
--- first hit's byte offsets (computed once, up front) stay valid after
--- the second hit's splice runs -- front-to-back would shift them out
--- from under it, corrupting the first hit's replacement into a syntax
--- error.
local function test_rewrite_applies_both_hits_in_a_two_hit_source()
  local pattern = pattern_ok("os.execute($X)")
  local source = "os.execute(cmd1)\nos.execute(cmd2)\n"
  local result, err = rewrite_mod.rewrite(
    built, source, "two.tl", pattern, "assert(os.execute($X))")
  assert(result ~= nil, "rewrite failed: " .. tostring(err))
  assert(#result.refused == 0, "expected no refusals")
  assert(result.code == "assert(os.execute(cmd1))\nassert(os.execute(cmd2))\n",
    "code: " .. result.code)
end

--- A comment sitting between the two captures -- in the gap the swapped
--- template doesn't cover -- is not carried forward by either capture's
--- own span, so the hit is refused: left byte-for-byte unmodified
--- (comment included) rather than silently mangled by the splice.
local function test_rewrite_refuses_a_hit_that_would_drop_a_comment()
  local pattern = pattern_ok("return $A + $B")
  local source = "return a --[[ keep this ]] + b\n"
  local result, err = rewrite_mod.rewrite(
    built, source, "refuse.tl", pattern, "return $B + $A")
  assert(result ~= nil, "rewrite failed: " .. tostring(err))
  assert(#result.refused == 1, "expected one refusal")
  assert(result.refused[1].comments[1] == "--[[ keep this ]]",
    "comment: " .. tostring(result.refused[1].comments[1]))
  assert(result.code == source, "code should be unchanged")
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
--- STRAY BLANK LINE mid-file.
local function test_rewrite_deletes_a_call_statement_leaving_no_blank_line()
  local pattern = pattern_ok("$F:^test_()")
  local source = "run()\ntest_a()\nrun()\n"
  local result, err = rewrite_mod.rewrite(built, source, "delete.tl", pattern, "")
  assert(result ~= nil, "rewrite failed: " .. tostring(err))
  assert(#result.refused == 0, "expected no refusals")
  assert(result.code == "run()\nrun()\n", "code: " .. result.code)
end

--- The same deletion, refusal side: a comment trailing the statement
--- on its OWN line sits outside the call node's own byte span but
--- inside the whole-line range the deletion removes -- the hit is
--- refused, exactly as a comment inside a normal splice's own span
--- would be, rather than silently vanishing with the line.
local function test_rewrite_refuses_a_statement_deletion_dropping_a_trailing_comment()
  local pattern = pattern_ok("$F:^test_()")
  local source = "test_a() -- keep this\nrun()\n"
  local result, err = rewrite_mod.rewrite(built, source, "refuse_delete.tl", pattern, "")
  assert(result ~= nil, "rewrite failed: " .. tostring(err))
  assert(#result.refused == 1, "expected one refusal")
  assert(result.refused[1].comments[1] == "-- keep this",
    "comment: " .. tostring(result.refused[1].comments[1]))
  assert(result.code == source, "code should be unchanged")
end

local function test_rewrite_reports_only_accepted_original_hits_in_source_order()
  local pattern = pattern_ok("os.execute($CMD)")
  local source = "os.execute(a)\nos.execute(b --[[ keep ]] )\nos.execute(c)\n"
  local result, err = rewrite_mod.rewrite(built, source, "edits.tl", pattern,
    "assert(os.execute($CMD))")
  assert(result ~= nil, "rewrite failed: " .. tostring(err))
  assert(#result.refused == 1, "expected one refusal")
  assert(#result.edits == 2, "expected two accepted edits")
  local y1, x1 = ast.span_start(result.edits[1].node)
  local y2, x2 = ast.span_start(result.edits[2].node)
  assert(y1 == 1 and x1 == 1 and y2 == 3 and x2 == 1,
    "accepted edit metadata must retain original positions")
  assert(result.code ==
    "assert(os.execute(a))\nos.execute(b --[[ keep ]] )\nassert(os.execute(c))\n",
    "code: " .. result.code)
end

local function test_rewrite_reports_deletion_as_an_accepted_edit()
  local pattern = pattern_ok("$F:^test_()")
  local result, err = rewrite_mod.rewrite(
    built, "test_a()\n", "delete_edits.tl", pattern, "")
  assert(result ~= nil, "rewrite failed: " .. tostring(err))
  assert(#result.edits == 1, "expected one accepted edit")
  assert(result.code == "", "code: " .. result.code)
end
