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
test_the_site_counts_match_the_committed_baseline()

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
  -- A function TYPE opens no block and closes on no `end`, so treating
  -- one as a definition would swallow the next `end` and charge every
  -- later return to the wrong function. Here the only `return nil` sits
  -- under a signature that admits nil, so any miscount shows up as a
  -- site this file must not have.
  local types = table.concat({
      "local type Handler = function(x: integer): string",
      "local record Sink",
      "  write: function(s: string): boolean",
      "end",
      "local function run(h: Handler, s: Sink): string | nil, string",
      "  if not s.write(h(1)) then",
      "    return nil, \"write failed\"",
      "  end",
      "  return h(2)",
      "end",
      "local function after(): string",
      "  return \"unaffected\"",
      "end",
      "print(run, after())",
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
  assert(fs.write(fs.join(root, "cosmic", "types.tl"), types))
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
  assert(got["cosmic/types.tl"] == nil,
    "a function TYPE opens no block, so nothing after it is miscounted: "
    .. tostring(got["cosmic/types.tl"]))
  assert(got["cosmic/quoted.tl"] == nil,
    "a return quoted inside a string is not a return")
  assert(got["cosmic/testdata/fixture.tl"] == nil, "testdata is skipped")
  assert(got["untracked/loose.tl"] == nil,
    "only the counted trees are walked")
end
test_count_reads_the_innermost_declared_return()

print("all nil-return ratchet tests passed")
