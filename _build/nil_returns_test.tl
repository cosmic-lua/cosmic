#!/usr/bin/env cosmic
--- reads: _build
--- reads: _cli
--- reads: _docs
--- reads: _eval
--- reads: _fuzz
--- reads: _make
--- reads: _perf
--- reads: _tool
--- reads: _types
--- reads: cmd
--- reads: cosmic
-- Ratchet over the tree's `return nil`-under-a-non-nil-signature count.
--
-- The checker accepts these, so nothing else in the toolchain can see
-- them: the type never admits nil, so no narrowing is ever demanded and
-- no caller is ever asked to guard. This gate holds the count per file
-- against a committed floor, in both directions: a file may not grow
-- sites, and a file that sheds them banks the improvement by failing
-- until the floor is rewritten. The floor therefore always says what
-- the tree actually carries, which is what makes it a measurement and
-- not a memory.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local nilret = require("_build.nil_returns")

local REBASELINE < const > =
"stale baseline — run: bin/cosmic --make run _build/nil_returns.tl" ..
" --baseline and commit the result"

-- The fixture runs FIRST and the tree-wide ratchet after it. A test
-- file stops at its first failing assertion, so the other order lets
-- a moved tree hide a broken rule behind a ratchet message about
-- counts -- and it was the ratchet, not the fixture, that caught
-- most of the mutations this fixture is written to catch.

-- What the count actually reads. The fixture pins each rule the
-- detector rests on: the declared slot 1 decides, the INNERMOST
-- enclosing function owns the return, a signature that admits nil is
-- not in the class at all, and the lexer is what reads the file — so a
-- `return nil` inside a string counts for nothing, and `testdata/` is
-- not the tree.
local function test_count_reads_the_innermost_declared_return()
  local root = fs.join(check.must(os.getenv("TEST_TMPDIR")), "nilret")
  local lies = table.concat({
      "local function bare(): string",
      "  return nil",
      "end",
      "local function effect(x: integer): boolean, string",
      "  if x < 0 then return nil, \"negative\" end",
      "  return true",
      "end",
      "print(bare(), effect(1))",
    }, "\n") .. "\n"
  local honest = table.concat({
      "local function union(): string | nil, string",
      "  return nil, \"no\"",
      "end",
      "local function anything(): any, string",
      "  return nil, \"no\"",
      "end",
      "local function undeclared()",
      "  return nil",
      "end",
      "print(union(), anything(), undeclared())",
    }, "\n") .. "\n"
  -- The outer function admits nil; the inner closure does not. Only the
  -- closure's return is in the class, and charging it outward — or
  -- inward — would count the wrong one.
  local nested = table.concat({
      "local function outer(): string | nil, string",
      "  local inner = function(): string",
      "    return nil",
      "  end",
      "  if inner() == nil then",
      "    return nil, \"inner\"",
      "  end",
      "  return inner()",
      "end",
      "print(outer())",
    }, "\n") .. "\n"
  -- Whether a `function` opens a body cannot be read off the token
  -- before it. Each of these declares its returns honestly and must
  -- count ZERO; each carries a function TYPE behind a `{`, a `<`, a `,`
  -- or a cast — exactly the tokens that also precede a real definition.
  -- A detector that decides backwards charges the honest `return nil`
  -- to a frame no `end` ever pops.
  local behind_brace = table.concat({
      "local function f(): string | nil, string",
      "  local hs: {function(): string} = {}",
      "  print(hs)",
      "  return nil, \"e\"",
      "end",
      "print(f())",
    }, "\n") .. "\n"
  local behind_angle = table.concat({
      "local function g(): string | nil, string",
      "  local b: Box<function(): string> = nil",
      "  print(b)",
      "  return nil, \"e\"",
      "end",
      "print(g())",
    }, "\n") .. "\n"
  local behind_comma = table.concat({
      "local function cfg(): boolean | nil, function(): integer",
      "  return nil, function(): integer return 1 end",
      "end",
      "print(cfg())",
    }, "\n") .. "\n"
  local behind_cast = table.concat({
      "local function pick(v: any): string | nil, string",
      "  local h = v as function(): string",
      "  if v is function(): integer then",
      "    print(h)",
      "  end",
      "  return nil, \"e\"",
      "end",
      "print(pick(1))",
    }, "\n") .. "\n"
  -- Lua 5.4 lexes `>>` as one token, so a nested generic's closing
  -- angles arrive together. A skip that counts that once leaves the
  -- outer `<` open to end of file — and the honest return below reads
  -- as a site. Spacing the angles apart makes it pass either way, which
  -- is why the case is written closed up.
  local nested_generic = table.concat({
      "local function f(): string | nil, string",
      "  local b: Box<Box<function(): string>> = nil",
      "  print(b)",
      "  return nil, \"e\"",
      "end",
      "print(f())",
    }, "\n") .. "\n"
  -- The other legal spelling of a record. `record` is an identifier
  -- atom to the type grammar, so an alias hands it to the type parser
  -- and the body is consumed rather than opened — leaving its `end` to
  -- pop the enclosing function, and the real site below it unseen.
  local alias_body = table.concat({
      "local function build(): string",
      "  local type Shape = record",
      "    n: integer",
      "  end",
      "  print(Shape)",
      "  return nil",
      "end",
      "print(build())",
    }, "\n") .. "\n"
  -- An enum alias is the same shape with a different tell: its body
  -- opens onto STRINGS, not a field name, so nothing AFTER it says a
  -- body follows and only the alias itself can report one.
  local alias_enum = table.concat({
      "local function pick(): string",
      "  local type Kind = enum",
      "    \"a\"",
      "    \"b\"",
      "  end",
      "  print(Kind)",
      "  return nil",
      "end",
      "print(pick())",
    }, "\n") .. "\n"
  -- The control the two aliases must not be bought with: `record` is an
  -- IDENTIFIER, so binding the value under its own name (`record =
  -- record`, as `cosmic/shape.tl` does in its export table) puts it
  -- right after an `=` too. Reading that `=` backwards opens a frame no
  -- `end` ever pops, the function's own `end` pops the frame instead,
  -- and the honest module-scope return below is charged to a function
  -- that closed three lines earlier.
  local value_named_record = table.concat({
      "local function record(): string",
      "  return \"r\"",
      "end",
      "local function lying(): string",
      "  local t = {record = record}",
      "  return t.record()",
      "end",
      "if lying() == \"\" then",
      "  return nil",
      "end",
    }, "\n") .. "\n"
  -- The control the four above must not be bought with: after a `,` in
  -- a CALL, `function` really does open a definition, and its own
  -- `: integer` is the signature that nil lies about. Blacklisting `,`
  -- silences the case above and this one with it.
  local real_after_comma = table.concat({
      "local function use(n: integer, cb: function(): integer): integer",
      "  return n + cb()",
      "end",
      "print(use(1, function(): integer return nil end))",
    }, "\n") .. "\n"
  -- `record`, `interface` and `enum` are IDENTIFIERS to the lexer, not
  -- keywords. A body that opens no frame still closes on its `end`,
  -- which pops the enclosing function instead — and the real site below
  -- it goes unseen.
  local inner_record = table.concat({
      "local function build(): string",
      "  local record Shape",
      "    n: integer",
      "  end",
      "  print(Shape)",
      "  return nil",
      "end",
      "print(build())",
    }, "\n") .. "\n"
  -- `macroexp` is a function under another name -- a parameter list, a
  -- declared return list, a body closed by `end` -- and an IDENTIFIER
  -- to the lexer. A head that swallows it as a name opens no frame, so
  -- its `end` pops whatever is beneath it: the record around a method,
  -- or nothing at module scope. Both spellings must balance.
  local macro_bodies = table.concat({
      "local macroexp twice(x: integer): integer",
      "  return x * 2",
      "end",
      "local record Shape",
      "  n: integer",
      "  area: function(self: Shape): integer = macroexp(self: Shape): integer",
      "    return self.n * self.n",
      "  end",
      "end",
      "local s: Shape = {n = 3}",
      "print(twice(s:area()))",
    }, "\n") .. "\n"
  -- And it lies about nil exactly like a function: the declared slot 1
  -- decides, whichever word opened the body.
  local macro_lying = table.concat({
      "local macroexp none(_x: integer): integer",
      "  return nil",
      "end",
      "print(none(1))",
    }, "\n") .. "\n"
  local quoted = table.concat({
      "local function fine(): string",
      "  local s = \"local function f(): string return nil end\"",
      "  return s",
      "end",
      "print(fine())",
    }, "\n") .. "\n"
  for _, dir in ipairs({"cosmic/testdata", "untracked"}) do
    assert(fs.make_dirs(fs.join(root, dir)))
  end
  assert(fs.write(fs.join(root, "cosmic", "lies.tl"), lies))
  assert(fs.write(fs.join(root, "cosmic", "honest.tl"), honest))
  assert(fs.write(fs.join(root, "cosmic", "nested.tl"), nested))
  assert(fs.write(fs.join(root, "cosmic", "brace.tl"), behind_brace))
  assert(fs.write(fs.join(root, "cosmic", "angle.tl"), behind_angle))
  assert(fs.write(fs.join(root, "cosmic", "comma.tl"), behind_comma))
  assert(fs.write(fs.join(root, "cosmic", "cast.tl"), behind_cast))
  assert(fs.write(fs.join(root, "cosmic", "generic.tl"), nested_generic))
  assert(fs.write(fs.join(root, "cosmic", "alias.tl"), alias_body))
  assert(fs.write(fs.join(root, "cosmic", "aenum.tl"), alias_enum))
  assert(fs.write(fs.join(root, "cosmic", "value.tl"), value_named_record))
  assert(fs.write(fs.join(root, "cosmic", "call.tl"), real_after_comma))
  assert(fs.write(fs.join(root, "cosmic", "inner.tl"), inner_record))
  assert(fs.write(fs.join(root, "cosmic", "macro.tl"), macro_bodies))
  assert(fs.write(fs.join(root, "cosmic", "mlie.tl"), macro_lying))
  assert(fs.write(fs.join(root, "cosmic", "quoted.tl"), quoted))
  assert(fs.write(fs.join(root, "cosmic", "testdata", "fixture.tl"), lies))
  assert(fs.write(fs.join(root, "untracked", "loose.tl"), lies))

  local got = nilret.count(root)
  assert(got["cosmic/lies.tl"] == 2,
    "a bare `: string` and a `: boolean, string` both count: "
    .. tostring(got["cosmic/lies.tl"]))
  assert(got["cosmic/honest.tl"] == nil,
    "`| nil`, `any` and an undeclared return are not in the class")
  assert(got["cosmic/nested.tl"] == 1,
    "the innermost function owns the return: "
    .. tostring(got["cosmic/nested.tl"]))
  for _, name in ipairs({"brace", "angle", "comma", "cast", "generic"}) do
    local key = "cosmic/" .. name .. ".tl"
    assert(got[key] == nil,
      ("a function type behind %s is not a definition, so the honest "
        .. "return above it is not charged to it: %s"):format(name,
        tostring(got[key])))
  end
  assert(got["cosmic/call.tl"] == 1,
    "after a comma in a CALL, function really does open a definition: "
    .. tostring(got["cosmic/call.tl"]))
  assert(got["cosmic/inner.tl"] == 1,
    "a record body opens a frame, so its end does not pop the function: "
    .. tostring(got["cosmic/inner.tl"]))
  assert(got["cosmic/alias.tl"] == 1,
    "and so does one an alias names, which the type parser would eat: "
    .. tostring(got["cosmic/alias.tl"]))
  assert(got["cosmic/aenum.tl"] == 1,
    "including an enum alias, whose body opens onto strings: "
    .. tostring(got["cosmic/aenum.tl"]))
  assert(got["cosmic/value.tl"] == nil,
    "a value bound under the name `record` opens no body, so the return"
    .. " below its function is nobody's: "
    .. tostring(got["cosmic/value.tl"]))
  assert(got["cosmic/macro.tl"] == nil,
    "a local macroexp and a record method macroexp each declare their"
    .. " returns honestly, so neither counts: "
    .. tostring(got["cosmic/macro.tl"]))
  assert(got["cosmic/mlie.tl"] == 1,
    "a macroexp opens a frame whose declared slot 1 decides, like a"
    .. " function: " .. tostring(got["cosmic/mlie.tl"]))
  assert(got["cosmic/quoted.tl"] == nil,
    "a return quoted inside a string is not a return")
  assert(got["cosmic/testdata/fixture.tl"] == nil, "testdata is skipped")
  assert(got["untracked/loose.tl"] == nil,
    "only the counted trees are walked")
  -- Every shape above is well-formed, so the walk that read it must
  -- close what it opened. A count that came out right over a stack
  -- that did not balance is right by accident, and the next shape of
  -- the same kind will not be.
  local bad = nilret.unbalanced(root)
  assert(#bad == 0,
    "the walk left a frame behind on a well-formed fixture:\n  "
    .. table.concat(bad, "\n  "))
end

-- The two ways a walk fails to balance, on a fixture that shows what
-- each looks like: a body that is never closed, and an `end` that
-- closes nothing. The tree-wide gate below rests on both being
-- reported, in the file's own name.
local function test_unbalanced_names_both_halves()
  local root = fs.join(check.must(os.getenv("TEST_TMPDIR")), "balance")
  assert(fs.make_dirs(fs.join(root, "cosmic")))
  assert(fs.write(fs.join(root, "cosmic", "open.tl"),
      "local function f(): string\n  return \"x\"\n"))
  assert(fs.write(fs.join(root, "cosmic", "stray.tl"),
      "local x = 1\nprint(x)\nend\n"))
  assert(fs.write(fs.join(root, "cosmic", "even.tl"),
      "local function f(): string\n  return \"x\"\nend\nprint(f())\n"))
  local got = nilret.unbalanced(root)
  assert(#got == 2, "two of three fixtures are unbalanced: "
    .. table.concat(got, "; "))
  assert(got[1] == "cosmic/open.tl: 1 frame(s) left open at end of file,"
    .. " 0 end(s) with nothing to pop", got[1])
  assert(got[2] == "cosmic/stray.tl: 0 frame(s) left open at end of file,"
    .. " 1 end(s) with nothing to pop", got[2])
end

-- The type grammar under the count, checked by the tree instead of by
-- imagination. Every committed source is well-formed, so a walk over
-- it must close what it opened: a frame left open, or an `end` with
-- nothing to pop, is a type-position shape the grammar mis-read — the
-- class that a nested generic's `>>` and an alias's `record` body were
-- each found in by hand. The fix is in `_cli/returns.tl` or
-- `_cli/nilreturn.tl`, never in the file this names.
local function test_the_walk_balances_over_every_committed_file()
  local bad = nilret.unbalanced(".")
  assert(#bad == 0,
    "the frame walk does not balance — the type grammar mis-reads a shape"
    .. " in:\n  " .. table.concat(bad, "\n  "))
end

local function test_the_site_counts_match_the_committed_baseline()
  local fresh = nilret.count(".")
  local base = check.must(nilret.baseline())
  local over: {string} = {}
  local under: {string} = {}
  for path, n in pairs(fresh) do
    local was = base[path] or 0
    if n > was then
      local at: {string} = {}
      for _, y in ipairs(nilret.lines_in(path)) do
        at[#at + 1] = tostring(y)
      end
      over[#over + 1] = string.format(
        "%s: %d sites (baseline %d) at line(s) %s — declare the return" ..
        " `T | nil` (or return a real value), do not widen the floor",
        path, n, was, table.concat(at, ", "))
    elseif n < was then
      under[#under + 1] = string.format(
        "%s: %d sites (baseline %d)", path, n, was)
    end
  end
  for path, was in pairs(base) do
    if not fresh[path] then
      under[#under + 1] = string.format(
        "%s: no sites left (baseline %d)", path, was)
    end
  end
  table.sort(over)
  table.sort(under)
  assert(#over == 0,
    "file(s) over their nil-return baseline:\n  " .. table.concat(over, "\n  "))
  assert(#under == 0,
    "file(s) under their nil-return baseline — " .. REBASELINE .. ":\n  " ..
    table.concat(under, "\n  "))
end

print("all nil-return ratchet tests passed")
