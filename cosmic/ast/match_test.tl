#!/usr/bin/env cosmic
--- reads: cosmic/check.tl _tool/doc/index.tl _types/tlast.tl
--- Correctness probes for `cosmic.ast.match`'s pattern matcher, plus
--- the four real-file reproductions the item's own spec was pulled
--- to: the same patterns run against the same files, re-checked
--- against the CURRENT tree rather than pasted as a fixed transcript.
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local match = require("cosmic.ast.match")
local node_mod = require("cosmic.ast.node")

local type Node = node_mod.Node

--- Parse `source`, asserting the parse itself succeeded.
--- @param source string Source text
--- @param name string Filename for diagnostics
--- @return Node The AST root
local function parse_ok(source: string, name: string): Node
  return check.must(node_mod.parse(source, name)).node
end

--- Compile `pattern_src`, asserting the compile itself succeeded.
--- @param pattern_src string A `$NAME`/`$$$NAME` pattern
--- @return Node The pattern's own top node
local function pattern_ok(pattern_src: string): Node
  return check.must(match.compile_pattern(pattern_src))
end

--- Every node in `root`'s tree that `pattern` matches, own to this
--- test file: `match()` tests one node at a time by design (a
--- whole-file walk is the separate walk item's job, out of this
--- item's scope), so counting real matches across a file needs a
--- throwaway recursive descent here, the same "AST as `{any: any}`"
--- shape `_tool/coverage/lines.tl`'s own walk already needs.
--- @param root Node The tree to search
--- @param pattern Node A compiled pattern
--- @return {Node} Every matching node, in traversal order
local function collect_matches(root: Node, pattern: Node): {Node}
  local hits: {Node} = {}
  local seen: {any: boolean} = {}
  local function walk(n: {any: any})
    if seen[n] then
      return
    end
    seen[n] = true
    local as_node = n as Node -- cast: a table walked from a real Node tree is one
    if match.match(pattern, as_node) then
      hits[#hits + 1] = as_node
    end
    for _, v in pairs(n) do
      if v is {any: any} then
        if v["kind"] then
          walk(v)
        else
          for _, e in ipairs(v as {any}) do -- cast: array view of a generic ast map
            if e is {any: any} and e["kind"] then
              walk(e)
            end
          end
        end
      end
    end
  end
  walk(root as {any: any}) -- cast: generic ast node view
  return hits
end

--- A bare `$X` in a value position (`f($X)`) parses as a "variable"
--- node -- the plain capture shape, no member-name involved.
local function test_value_position_capture_binds_variable_kind()
  local pattern = pattern_ok("print($X)")
  local candidate = parse_ok("print(y)", "value.tl")[1]
  local caps = match.match(pattern, candidate)
  assert(caps ~= nil, "expected a match")
  local cap = caps["_X"]
  assert(cap ~= nil and cap.kind == "variable" and cap.tk == "y",
    "captured node: " .. tostring(cap and cap.kind) .. " " .. tostring(cap and cap.tk))
end

--- The regression this item exists to hold: the SAME `$F` used as a
--- member name (`cosmo.$F(...)`) parses as an "identifier" node, not
--- "variable" -- a capture check gated on `kind == "variable"` alone
--- silently matches nothing here, until it is widened to accept
--- either kind.
local function test_member_position_capture_binds_identifier_kind()
  local pattern = pattern_ok("cosmo.$F(1)")
  local candidate = parse_ok("cosmo.Slurp(1)", "member.tl")[1]
  local caps = match.match(pattern, candidate)
  assert(caps ~= nil, "cosmo.$F(...) must match a real cosmo.Slurp(...) call site")
  local cap = caps["_F"]
  assert(cap ~= nil and cap.kind == "identifier" and cap.tk == "Slurp",
    "captured node: " .. tostring(cap and cap.kind) .. " " .. tostring(cap and cap.tk))
end

--- A linear pattern: a capture name repeated in the pattern must bind
--- the SAME subtree every time it recurs, not merely two subtrees of
--- the same shape.
local function test_repeated_capture_name_is_linear()
  local pattern = pattern_ok("f($X, $X)")
  local same = parse_ok("f(y, y)", "same.tl")[1]
  local different = parse_ok("f(y, z)", "different.tl")[1]
  assert(match.match(pattern, same) ~= nil, "f(y, y) must match f($X, $X)")
  assert(match.match(pattern, different) == nil,
    "f(y, z) must NOT match f($X, $X): $X is bound twice to different names")
end

--- A rest-capture in an expression position (call args) swallows
--- every trailing argument, including zero of them.
local function test_rest_capture_matches_variable_arity_call_args()
  local pattern = pattern_ok("f($$$ARGS)")
  local three = parse_ok("f(1, 2, 3)", "three.tl")[1]
  local caps3 = match.match(pattern, three)
  assert(caps3 ~= nil, "expected a match")
  assert(#caps3["___ARGS"] == 3, "expected 3 captured args, got " .. tostring(#caps3["___ARGS"]))

  local zero = parse_ok("f()", "zero.tl")[1]
  local caps0 = match.match(pattern, zero)
  assert(caps0 ~= nil, "f() must match f($$$ARGS) with zero trailing args")
  assert(#caps0["___ARGS"] == 0, "expected 0 captured args, got " .. tostring(#caps0["___ARGS"]))
end

--- A rest-capture in a STATEMENT-list position must be spelled
--- `$$$NAME()` (a zero-arg call) in the pattern, never bare `$$$NAME`
--- -- Lua/Teal has no bare-expression-as-statement syntax, so the
--- bare spelling fails to even PARSE as a pattern.
local function test_bare_rest_capture_is_not_a_legal_statement()
  local pattern, err = match.compile_pattern("if $C then $$$BODY end")
  assert(pattern == nil, "a bare $$$BODY in a block position must fail to compile")
  assert(err ~= nil and err ~= "", "expected a parse error message")
end

--- The call-spelled rest-capture in a statement-list position matches
--- a real multi-statement body, including the tk exclusion this
--- pattern shape depends on: the body's "statements" node opens on
--- whichever token starts the FIRST statement, which differs, by
--- construction, between the pattern (`___BODY`) and any real target
--- -- comparing it generically would fail every match this pattern
--- could ever make.
local function test_rest_capture_in_block_matches_and_ignores_tk()
  local pattern = pattern_ok("if $C then $$$BODY() end")
  local candidate = parse_ok("if a then print(1)\nprint(2) end", "block.tl")[1]
  local caps = match.match(pattern, candidate)
  assert(caps ~= nil, "if $C then $$$BODY() end must match a real if with a differing" ..
    " first-statement token")
  assert(#caps["___BODY"] == 2, "expected 2 captured body statements, got "
    .. tostring(#caps["___BODY"]))
end

--- `tk` is excluded from the generic field walk only for a COMPOUND
--- node; a "variable"/"identifier"/"string" LEAF still compares `tk`
--- explicitly, so a literal, non-capture name in the pattern must
--- still match exactly.
local function test_tk_still_compared_on_leaf_kinds()
  local pattern = pattern_ok("print(1)")
  local same_name = parse_ok("print(1)", "same_name.tl")[1]
  local other_name = parse_ok("output(1)", "other_name.tl")[1]
  assert(match.match(pattern, same_name) ~= nil, "print(1) must match print(1)")
  assert(match.match(pattern, other_name) == nil,
    "output(1) must NOT match print(1): the literal callee name differs")
end

--- `desugar` rewrites both metavariable spellings before lexing, and
--- leaves everything else byte-for-byte -- confirmed directly rather
--- than only through a compiled pattern's behavior, since a pattern
--- with no metavariables at all would never exercise this at all.
local function test_desugar_rewrites_both_spellings()
  assert(match.desugar("f($X, $$$REST)") == "f(_X, ___REST)",
    "desugar: " .. match.desugar("f($X, $$$REST)"))
  assert(match.desugar("os.execute(cmd)") == "os.execute(cmd)",
    "desugar must leave metavariable-free source untouched")
end

--- `os.execute($X)` against `_types/tlast.tl`.
local function test_acceptance_os_execute_against_tlast()
  local pattern = pattern_ok("os.execute($X)")
  local source = check.must(fs.read("_types/tlast.tl"))
  local root = parse_ok(source, "_types/tlast.tl")
  local hits = collect_matches(root, pattern)
  assert(#hits == 1, "expected 1 match, got " .. tostring(#hits))
end

--- `string.format($FMT, $$$REST)` against `cosmic/check.tl`: five call
--- sites at variable arity.
local function test_acceptance_string_format_against_check()
  local pattern = pattern_ok("string.format($FMT, $$$REST)")
  local source = check.must(fs.read("cosmic/check.tl"))
  local root = parse_ok(source, "cosmic/check.tl")
  local hits = collect_matches(root, pattern)
  assert(#hits == 5, "expected 5 matches, got " .. tostring(#hits))
end

--- `if $C then $$$BODY() end` against `cosmic/check.tl`: every `if`
--- with no `elseif`/`else` -- this pattern's if_blocks array has
--- exactly one element with no rest-capture marker of its own, so
--- match_list's own exact-length branch (not the rest-capture branch)
--- is what rules out any `if` carrying an `elseif` or `else`.
local function test_acceptance_if_then_body_against_check()
  local pattern = pattern_ok("if $C then $$$BODY() end")
  local source = check.must(fs.read("cosmic/check.tl"))
  local root = parse_ok(source, "cosmic/check.tl")
  local hits = collect_matches(root, pattern)
  assert(#hits == 25, "expected 25 matches, got " .. tostring(#hits))
end

--- `cosmo.$F($$$ARGS)` against `_tool/doc/index.tl`: the
--- identifier-position-capture regression case, on a real file.
local function test_acceptance_cosmo_call_against_doc_index()
  local pattern = pattern_ok("cosmo.$F($$$ARGS)")
  local source = check.must(fs.read("_tool/doc/index.tl"))
  local root = parse_ok(source, "_tool/doc/index.tl")
  local hits = collect_matches(root, pattern)
  assert(#hits == 2, "expected 2 matches, got " .. tostring(#hits))
end
