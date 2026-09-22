--- Correctness probes for `build.ast.match`.
local teal = require("build.teal")
local match = require("build.ast.match")
local node_mod = require("build.ast.node")

local type Node = node_mod.Node

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Parse `source`, asserting the parse itself succeeded.
--- @param source string Source text
--- @param name string Filename for diagnostics
--- @return Node The AST root
local function parse_ok(source: string, name: string): Node
  local parsed, err = node_mod.parse(built, source, name)
  assert(parsed ~= nil, "parse failed: " .. tostring(err))
  return parsed.node
end

--- Compile `pattern_src`, asserting the compile itself succeeded.
--- @param pattern_src string A `$NAME`/`$$$NAME` pattern
--- @return Node The pattern's own top node
local function pattern_ok(pattern_src: string): Node
  local pattern, err = match.compile_pattern(built, pattern_src)
  assert(pattern ~= nil, "compile_pattern failed: " .. tostring(err))
  return pattern
end

--- Each parse allocates fresh typeids for the declaration tuple and
--- its nested annotation types; identical source must still match.
local function test_typed_declarations_match_across_separate_parses()
  for _, scope in ipairs({ "local", "global" }) do
    for _, annotation in ipairs({ "number", "{string: {number}}",
        "function(number): string", "Box<string>" }) do
      local source = scope .. " value: " .. annotation .. " = make_value()"
      local pattern = pattern_ok(source)
      local candidate = parse_ok(source, "typed_declaration.tl")[1]
      assert(match.match(pattern, candidate) ~= nil,
        "separately parsed declaration must match: " .. source)
    end
  end
end

--- Ignoring parser ids must preserve the annotation's source shape,
--- including primitive names and types nested inside containers.
local function test_typed_declarations_still_compare_annotation_shape()
  for _, scope in ipairs({ "local", "global" }) do
    local prefix = scope .. " value: "
    local pattern = pattern_ok(prefix .. "{string: {number}} = make_value()")
    for _, annotation in ipairs({ "number", "{string: {string}}",
        "{number: {number}}" }) do
      local candidate = parse_ok(prefix .. annotation .. " = make_value()",
        "different_annotation.tl")[1]
      assert(match.match(pattern, candidate) == nil,
        "different annotation must not match: " .. annotation)
    end
  end
end

--- A source-authored record field named `typeid` is a type value,
--- not the parser's numeric allocation id on the enclosing type node.
local function test_record_typeid_field_still_compares_its_declared_type()
  for _, scope in ipairs({ "local", "global" }) do
    for _, field in ipairs({ "typeid", "ordinary" }) do
      local prefix = scope .. " record Box " .. field .. ": "
      local source = prefix .. "number end"
      local pattern = pattern_ok(source)
      local same = parse_ok(source, "same_record.tl")[1]
      local different = parse_ok(prefix .. "string end", "different_record.tl")[1]
      assert(match.match(pattern, same) ~= nil,
        "separately parsed record must match: " .. source)
      assert(match.match(pattern, different) == nil,
        "record field's declared type must be compared: " .. scope .. " " .. field)
    end
  end
end

--- Every node in `root`'s tree that `pattern` matches, own to this
--- test file: `match()` tests one node at a time by design (a
--- whole-file walk is `build.ast.rewrite`'s `find_all` job, out of
--- this item's scope), so counting real matches across a fixture needs
--- a throwaway recursive descent here, the same "AST as `{any: any}`"
--- shape a generic walk over tl's own output already needs.
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
--- member name (`mod.$F(...)`) parses as an "identifier" node, not
--- "variable" -- a capture check gated on `kind == "variable"` alone
--- silently matches nothing here, until it is widened to accept
--- either kind.
local function test_member_position_capture_binds_identifier_kind()
  local pattern = pattern_ok("mod.$F(1)")
  local candidate = parse_ok("mod.load(1)", "member.tl")[1]
  local caps = match.match(pattern, candidate)
  assert(caps ~= nil, "mod.$F(...) must match a real mod.load(...) call site")
  local cap = caps["_F"]
  assert(cap ~= nil and cap.kind == "identifier" and cap.tk == "load",
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
  assert(#caps3["___ARGS"] == 3,
    "expected 3 captured args, got " .. tostring(#caps3["___ARGS"]))

  local zero = parse_ok("f()", "zero.tl")[1]
  local caps0 = match.match(pattern, zero)
  assert(caps0 ~= nil, "f() must match f($$$ARGS) with zero trailing args")
  assert(#caps0["___ARGS"] == 0,
    "expected 0 captured args, got " .. tostring(#caps0["___ARGS"]))
end

--- A rest-capture in a STATEMENT-list position must be spelled
--- `$$$NAME()` (a zero-arg call) in the pattern, never bare `$$$NAME`
--- -- Lua/Teal has no bare-expression-as-statement syntax, so the
--- bare spelling fails to even PARSE as a pattern.
local function test_bare_rest_capture_is_not_a_legal_statement()
  local pattern, err = match.compile_pattern(built, "if $C then $$$BODY end")
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

--- A capture's `:PATTERN` predicate suffix restricts which candidates
--- it binds: `$F:^test_()` matches `test_a()` (whose callee's own `tk`
--- starts with `test_`) but not `run()`.
local function test_capture_predicate_matches_only_names_the_pattern_allows()
  local pattern = pattern_ok("$F:^test_()")
  local hit = parse_ok("test_a()", "hit.tl")[1]
  local miss = parse_ok("run()", "miss.tl")[1]
  local caps = match.match(pattern, hit)
  assert(caps ~= nil, "test_a() must match $F:^test_()")
  assert(caps["_F"] ~= nil and caps["_F"].tk == "test_a",
    "captured node: " .. tostring(caps["_F"] and caps["_F"].tk))
  assert(match.match(pattern, miss) == nil,
    "run() must NOT match $F:^test_(): its name fails the ^test_ predicate")
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
  assert(match.desugar("$F:^test_()") == "_F()",
    "desugar: " .. match.desugar("$F:^test_()"))
end

--- `os.execute($X)` over a small multi-statement fixture with exactly
--- one matching call among unrelated ones.
local function test_acceptance_os_execute_over_multiple_statements()
  local pattern = pattern_ok("os.execute($X)")
  local source = [[
print("a")
os.execute("true")
print("b")
]]
  local root = parse_ok(source, "acceptance_execute.tl")
  local hits = collect_matches(root, pattern)
  assert(#hits == 1, "expected 1 match, got " .. tostring(#hits))
end

--- `string.format($FMT, $$$REST)` over three calls at different
--- arities plus one unrelated call.
local function test_acceptance_string_format_over_multiple_statements()
  local pattern = pattern_ok("string.format($FMT, $$$REST)")
  local source = [[
local a = string.format("%d", 1)
local b = string.format("%s %s", "x", "y")
local c = string.format("%d %d %d", 1, 2, 3)
print("not a format call")
]]
  local root = parse_ok(source, "acceptance_format.tl")
  local hits = collect_matches(root, pattern)
  assert(#hits == 3, "expected 3 matches, got " .. tostring(#hits))
end

--- `if $C then $$$BODY() end` over three `if` statements: a plain one
--- (one if_block, matches), one with an `elseif` (two if_blocks), and
--- one with an `else` (also two if_blocks, since tl's own parser
--- appends the else branch as an extra if_block with no `exp`) --
--- `match_list`'s own exact-length branch rules out both of the
--- latter, the same way it does over a whole real file.
local function test_acceptance_if_then_body_over_multiple_branches()
  local pattern = pattern_ok("if $C then $$$BODY() end")
  local source = [[
if a then
  print(1)
end
if b then
  print(2)
  print(3)
elseif c then
  print(4)
end
if d then
  print(5)
else
  print(6)
end
]]
  local root = parse_ok(source, "acceptance_if.tl")
  local hits = collect_matches(root, pattern)
  assert(#hits == 1, "expected 1 match, got " .. tostring(#hits))
end

--- `mod.$F($$$ARGS)` over two calls on `mod` and one on a different
--- namespace -- the identifier-position-capture regression case, at
--- more than one call site.
local function test_acceptance_member_call_over_multiple_statements()
  local pattern = pattern_ok("mod.$F($$$ARGS)")
  local source = [[
mod.foo(1, 2)
mod.bar()
other.foo(1)
]]
  local root = parse_ok(source, "acceptance_member.tl")
  local hits = collect_matches(root, pattern)
  assert(#hits == 2, "expected 2 matches, got " .. tostring(#hits))
end

--- Two probe casts, side by side: one to a primitive, one to a map --
--- the fixture the `$X as ...` tests below all share.
--- @return Node Parsed root: `local v ... / a = v as integer / b = v as {string: any}`
local function cast_probe_root(): Node
  return parse_ok([[
local v: any = 1
local a = v as integer
local b = v as {string: any}
]], "cast_probe.tl")
end

--- A cast is matchable by LITERAL type text: `$X as integer` binds
--- only the site whose own rendered type is exactly `integer`, not
--- the map cast sitting right beside it.
local function test_cast_literal_type_matches_only_that_rendered_type()
  local pattern = pattern_ok("$X as integer")
  local hits = collect_matches(cast_probe_root(), pattern)
  assert(#hits == 1, "expected 1 match, got " .. tostring(#hits))
end

--- `$X as $T` is a capture in TYPE position: it binds BOTH probe
--- casts, one per site, and `$T` itself binds the candidate's own
--- `cast` node (not a copy of its type, not the surrounding `as`).
local function test_cast_capture_binds_every_cast_and_the_cast_node()
  local pattern = pattern_ok("$X as $T")
  local root = cast_probe_root()
  local hits = collect_matches(root, pattern)
  assert(#hits == 2, "expected 2 matches, got " .. tostring(#hits))
  local exps = root[3].exps -- `local b = v as {string: any}`
  assert(exps ~= nil, "no local b's exps")
  local caps = match.match(pattern, exps[1])
  assert(caps ~= nil, "expected a match")
  local cap = caps["_T"]
  assert(cap ~= nil, "no $T capture")
  assert(cap.kind == "cast", "captured $T must be the `cast` node, got " .. cap.kind)
end

--- `$X as $T:^{` -- the same `:PATTERN` predicate mechanism as any
--- other capture, applied here to the cast's RENDERED type text
--- instead of a node's own `tk`: selects the map cast (its rendered
--- text starts with `{`) and excludes the integer cast beside it.
local function test_cast_capture_predicate_filters_by_rendered_type()
  local pattern = pattern_ok("$X as $T:^{")
  local hits = collect_matches(cast_probe_root(), pattern)
  assert(#hits == 1, "expected 1 match, got " .. tostring(#hits))
end

--- A cast's own operand may itself be a pattern: `f($A) as Foo`
--- matches a call operand cast to a literal nominal type.
local function test_cast_operand_may_be_a_call_pattern()
  local pattern = pattern_ok("f($A) as Foo")
  local hit = parse_ok("local c = f(x) as Foo", "call_cast.tl")
  local miss = parse_ok("local c = g(x) as Foo", "call_cast_miss.tl")
  assert(#collect_matches(hit, pattern) == 1, "f(x) as Foo must match f($A) as Foo")
  assert(#collect_matches(miss, pattern) == 0,
    "g(x) as Foo must NOT match f($A) as Foo: the callee name differs")
end
