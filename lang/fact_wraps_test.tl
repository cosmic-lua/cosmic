--- Tests of [`lang.fact_wraps`]: the arguments of the call of `__fact` that wraps each narrowed read, and the place
--- (`file:line:column`) each is given.
local Check = require("lang.check")
local FactWraps = require("lang.fact_wraps")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

local SOURCE <const> = table.concat({
  "local enum Color",
  "  \"red\"",
  "end",
  "local function f(x: string?, c: Color | integer): string",
  "  if x == nil then return \"-\" end",
  "  if c is Color then",
  "    return x .. c",
  "  end",
  "  return x",
  "end",
  "",
}, "\n")

local function test_each_narrowed_read_is_wrapped_with_its_place()
  local run = Programs.run(SOURCE)
  assert(Programs.codes(run) == "", Programs.codes(run))
  local wraps = FactWraps.of(run.result.narrowed, SOURCE, "m.tl")
  local seen = ""
  for _, n in ipairs(run.result.narrowed) do
    seen = seen .. n.text .. "=" .. (wraps[n.id] or "?") .. "\n"
  end
  local want = table.concat({
    "x=\"nil\", \"x\", nil, nil, nil, nil, \"m.tl:7:12\"",
    "c=\"number\", \"c\", nil, nil, nil, nil, \"m.tl:7:17\"",
    "x=\"nil\", \"x\", nil, nil, nil, nil, \"m.tl:9:10\"",
    "",
  }, "\n")
  assert(seen == want, seen)
end

local function test_a_place_is_one_based_at_the_first_byte_of_the_read()
  local run = Programs.run(SOURCE)
  local first = assert(run.result.narrowed[1])
  local wraps = FactWraps.of({ first }, SOURCE, "a/b.tl")
  local wrapped = assert(wraps[first.id])
  assert(wrapped:find("\"a/b.tl:7:12\"$") ~= nil, wrapped)
  -- The same offset at the start of the text is line 1, column 1.
  local lone: Check.Narrowed = {
    id = 1, offset = 1, length = 1, text = "x", taken = { "nil", "boolean" }, strings = nil, classes = nil, tag = nil,
    tags = nil,
  }
  assert(FactWraps.of({ lone }, "x", "z.tl")[1] == "\"nil,boolean\", \"x\", nil, nil, nil, nil, \"z.tl:1:1\"")
end

local function test_the_values_of_a_tag_are_one_string_constant()
  local tagged: Check.Narrowed = {
    id = 3, offset = 1, length = 1, text = "s", taken = { "nil" }, strings = nil, classes = nil, tag = "kind",
    tags = { "square", "circle" },
  }
  assert(FactWraps.arguments(tagged, "f.tl:1:1") == "\"nil\", \"s\", nil, nil, \"kind\", \"square,circle\", \"f.tl:1:1\"")
end

local function test_a_string_with_a_newline_or_a_quote_is_one_line_of_lua()
  local odd: Check.Narrowed = {
    id = 2, offset = 1, length = 1, text = "a\"b\nc", taken = { "nil" }, strings = { "q\"", "n\n" }, classes = nil,
    tag = nil, tags = nil,
  }
  local text = FactWraps.arguments(odd, "f.tl:1:1")
  assert(not text:find("\n", 1, true), text)
  local chunk = assert(load("local t = {" .. text .. "}\nreturn t[2] == \"a\\\"b\\nc\" and t[3][2] == \"n\\n\" and t[4] == nil"))
  assert(chunk() == true, text)
end

local TAGGED <const> = table.concat({
  "local enum A_kind \"a\" end",
  "local enum B_kind \"b\" end",
  "local record A",
  "  kind: A_kind",
  "  n: integer",
  "end",
  "local record B",
  "  kind: B_kind",
  "  s: string",
  "end",
  "local type U = A | B",
  "",
}, "\n")

--- The calls of `__fact` in the Lua of `body` after the declarations of a tagged union, run with its facts checked, and the
--- Lua.
local function facts_of(body: string): integer, string
  local ran = Programs.execute(TAGGED .. body, true)
  assert(ran.ran and ran.fault == nil, tostring(ran.fault) .. " in " .. body)
  local count = 0
  for _ in ran.lua:gmatch("__fact%(") do
    count = count + 1
  end
  return count, ran.lua
end

local function test_a_narrowing_is_checked_once_for_reads_that_nothing_comes_between()
  local count = facts_of(table.concat({
    "local function f(u: U): integer",
    "  if u.kind == \"a\" then",
    "    return u.n + u.n + u.n",
    "  end",
    "  return 0",
    "end",
    "print(f({ kind = \"a\", n = 2 }))",
    "",
  }, "\n"))
  assert(count == 1, tostring(count))
end

local function test_a_narrowing_is_checked_again_after_a_call_or_a_write()
  local called = facts_of(table.concat({
    "local function f(u: U, h: function()): integer",
    "  if u.kind == \"a\" then",
    "    local before = u.n",
    "    h()",
    "    return before + u.n",
    "  end",
    "  return 0",
    "end",
    "print(f({ kind = \"a\", n = 2 }, function() end))",
    "",
  }, "\n"))
  assert(called == 2, tostring(called))
  local written = facts_of(table.concat({
    "local function f(u: U, v: U): integer",
    "  if u.kind == \"a\" then",
    "    local before = u.n",
    "    u = v",
    "    if u.kind == \"a\" then",
    "      return before + u.n",
    "    end",
    "  end",
    "  return 0",
    "end",
    "print(f({ kind = \"a\", n = 2 }, { kind = \"a\", n = 3 }))",
    "",
  }, "\n"))
  assert(written == 2, tostring(written))
end

local function test_an_element_a_length_test_proves_is_a_narrowed_read_like_a_local()
  -- `xs[1]` starts where the narrowed `xs` it reads does: both are kept, each checked.
  local source = table.concat({
    "local function f(xs: {string}?): string",
    "  if xs == nil or #xs < 1 then return \"-\" end",
    "  return xs[1]",
    "end",
    "",
  }, "\n")
  local run = Programs.run(source)
  assert(Programs.codes(run) == "", Programs.codes(run))
  local seen: mut {string} = {}
  for _, n in ipairs(run.result.narrowed) do
    seen[#seen + 1] = n.text .. ":" .. table.concat(n.taken, ",")
  end
  table.sort(seen)
  assert(table.concat(seen, " ") == "xs:nil xs:nil xs[1]:nil", table.concat(seen, " "))
end

local function test_a_write_to_an_element_a_length_test_proves_is_not_a_read()
  local source = table.concat({
    "local xs: mut {string} = { \"a\" }",
    "if #xs >= 1 then",
    "  xs[1] = \"b\"",
    "end",
    "print(xs[1])",
    "",
  }, "\n")
  local run = Programs.run(source)
  assert(Programs.codes(run) == "", Programs.codes(run))
  for _, n in ipairs(run.result.narrowed) do
    assert(n.text:find("[", 1, true) == nil, n.text)
  end
  local done = Programs.execute(source, true)
  assert(done.fault == nil, done.fault)
  assert(done.printed[1] == "b", done.printed[1])
end

local function test_a_read_in_a_branch_that_may_not_run_is_not_covered_by_one_after_it()
  local count = facts_of(table.concat({
    "local function f(u: U, c: boolean): integer",
    "  if u.kind == \"a\" then",
    "    local first = 0",
    "    if c then",
    "      first = u.n",
    "    end",
    "    return first + u.n",
    "  end",
    "  return 0",
    "end",
    "print(f({ kind = \"a\", n = 2 }, false))",
    "",
  }, "\n"))
  assert(count == 2, tostring(count))
end

local function test_the_remainder_of_a_chain_is_checked_where_a_read_relies_on_it()
  local count, lua = facts_of(table.concat({
    "local function f(u: U): string",
    "  if u.kind == \"a\" then",
    "    return \"a\"",
    "  else",
    "    return u.s",
    "  end",
    "end",
    "print(f({ kind = \"b\", s = \"x\" }))",
    "",
  }, "\n"))
  assert(count == 1 and lua:find("\"kind\", \"b\"", 1, true) ~= nil, lua)
end

local function test_a_tag_compared_to_a_string_is_not_checked_but_the_read_that_follows_is()
  local count = facts_of(table.concat({
    "local function f(u: U): string",
    "  if u.kind == \"a\" then",
    "    return \"a\"",
    "  elseif u.kind == \"b\" then",
    "    return u.s",
    "  end",
    "end",
    "print(f({ kind = \"b\", s = \"x\" }))",
    "",
  }, "\n"))
  assert(count == 1, tostring(count))
end

local function test_a_tag_read_after_a_test_of_it_and_a_call_is_checked()
  local count = facts_of(table.concat({
    "local enum C_kind \"c\" end",
    "local record C",
    "  kind: C_kind",
    "end",
    "local record Box",
    "  s: A | B | C",
    "end",
    "local function f(b: Box, poke: function()): string",
    "  if b.s.kind == \"a\" then return \"a\" end",
    "  poke()",
    "  local k = b.s.kind",
    "  if k == \"b\" then return \"b\" end",
    "  return k",
    "end",
    "print(f({ s = { kind = \"b\", s = \"x\" } }, function() end))",
    "",
  }, "\n"))
  assert(count == 1, tostring(count))
end

local function test_the_last_test_of_a_chain_that_names_every_member_is_checked()
  local returned = facts_of(table.concat({
    "local enum C_kind \"c\" end",
    "local record C",
    "  kind: C_kind",
    "end",
    "local function f(x: A | B | C): integer",
    "  if x.kind == \"a\" then return 1 elseif x.kind == \"b\" then return 2 elseif x.kind == \"c\" then return 3 end",
    "end",
    "print(f({ kind = \"b\", s = \"x\" }))",
    "",
  }, "\n"))
  assert(returned == 1, tostring(returned))
  local assigned = facts_of(table.concat({
    "local enum C_kind \"c\" end",
    "local record C",
    "  kind: C_kind",
    "end",
    "local function f(x: A | B | C): integer",
    "  local r: integer",
    "  if x.kind == \"a\" then r = 1 elseif x.kind == \"b\" then r = 2 elseif x.kind == \"c\" then r = 3 end",
    "  return r",
    "end",
    "print(f({ kind = \"b\", s = \"x\" }))",
    "",
  }, "\n"))
  assert(assigned == 1, tostring(assigned))
end
