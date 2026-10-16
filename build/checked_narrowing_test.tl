--- Checked narrowing: under the checker's `runtime_checks` option
--- ([`importer.compile`]'s `checks`, `cosmic test --check-types`), each read
--- whose type a fact narrowed (`if x then`, `x ~= nil`, `is`, `type(x) ==`,
--- `assert`) is written as a check of the fact, and the test worker's hook ([`worker.install_checks`]) raises
--- "fact violated at <file>:<y>:<x>" for a value the fact is false of. A
--- compile without the option writes none of it.

local teal = require("build.teal")
local worker = require("build.test_worker")

--- `source` compiled as the file "snippet", with the checks or without, as
--- the Lua text the build writes. Fails when the checker refuses it.
local function compiled(source: string, checks: boolean): string
  local built = assert(teal.load(true))
  local env = assert(built.new_env({ defaults = {
    feat_lax = "off", gen_compat = "off", gen_target = "5.4", runtime_checks = checks,
  } }))
  local result = built.check_string(source, env, "snippet", "tl")
  local problems: {string} = {}
  for _, list in ipairs({ result.syntax_errors, result.type_errors }) do
    for _, each in ipairs(list) do
      problems[#problems + 1] = each.y .. ":" .. each.x .. ": " .. each.msg
    end
  end
  assert(#problems == 0, "the fixture does not compile: " .. table.concat(problems, "\n"))
  return (assert(built.generate(result.ast, "5.4", nil)))
end

--- The line of `source` that holds `text`, and the column `text` starts at.
local function place_of(source: string, text: string): integer, integer
  local line = 0
  for each in (source .. "\n"):gmatch("([^\n]*)\n") do
    line = line + 1
    local at = each:find(text, 1, true)
    if at then return line, at end
  end
  error("no line holds " .. text)
end

local function count_of(text: string, what: string): integer
  local n = 0
  for _ in text:gmatch(what) do n = n + 1 end
  return n
end

--- `assert(x)` narrows `x`. A function that stands in for `assert` and does not
--- raise leaves the nil the checker proved away.
local lie_source = table.concat({
  "local function read(x: string | nil): string",
  "  assert(x)",
  "  return x",
  "end",
  "return { read = read }",
  "",
}, "\n")

local record Raising
  read: function(any): string
end

--- The failure a function raises, or nil.
local function failure(fn: function(): any): string
  local ok, err = pcall(fn)
  if ok then return nil end
  return tostring(err)
end

--- Returns what it is given, as an `assert` that does not check would.
local function unchecked(...: any): any...
  return ...
end

local function test_a_narrowed_read_whose_fact_is_false_raises()
  worker.install_checks()
  local chunk = assert(load(compiled(lie_source, true), "=snippet", "t"))
  local fixture = chunk() as Raising
  local line, column = place_of(lie_source, "return x")
  local globals = _G as {string:any}
  local real = globals.assert
  globals.assert = unchecked
  local message = failure(function(): any return fixture.read(nil) end)
  globals.assert = real
  assert(message ~= nil, "the read of x was not refused")
  local at = "fact violated at snippet:" .. line .. ":" .. (column + #"return ") .. ":"
  assert(message:find(at, 1, true), message)
  assert(message:find("x is nil", 1, true) and message:find("nil", 1, true), message)
end

--- A test of a field or a global narrows nothing, so no read of one is
--- written as a check: a field served lazily by `__index`, read again after
--- its test, has no fact to violate.
local function test_a_read_of_a_field_is_not_checked()
  local source = table.concat({
    "local record Lazy",
    "  a: string | nil",
    "  metamethod __index: function(Lazy, string): string | nil",
    "end",
    "global shared: string | nil",
    "local function read_twice(r: Lazy): string",
    "  if r.a then",
    "    return r.a",
    "  end",
    "  if shared then",
    "    return shared",
    "  end",
    "  return \"\"",
    "end",
    "return read_twice",
    "",
  }, "\n")
  local code = compiled(source, true)
  assert(not code:find("n;snippet", 1, true), "a read of a field or a global was checked: " .. code)
end

--- What the hook holds a value to, from the specs the code generator writes:
--- not the kinds a test took out ("~"), else the kinds the value has, an
--- integer by `math.type`.
local function test_the_hook_holds_a_value_to_its_fact()
  worker.install_checks()
  local hook = (_G as {string:any}).__cosmic_tc as function(integer, string, any...): any...
  local function refused(spec: string, value: any): string
    local ok, err = pcall(hook, 2, spec, value)
    assert(not ok, spec .. " passed " .. tostring(value))
    return tostring(err)
  end
  assert(hook(2, "n;f.tl:3:4;x;~nil", "a") == "a")
  assert(hook(2, "n;f.tl:3:4;x;~nil", false) == false, "false is a value")
  local message = refused("n;f.tl:3:4;x;~nil", nil)
  assert(message:find("fact violated at f.tl:3:4: x is nil", 1, true), message)
  assert(message:find("the checker proved not nil", 1, true), message)
  assert(hook(2, "n;f.tl:3:4;x;~string|table", nil) == nil, "a kind that was not taken out")
  assert(refused("n;f.tl:3:4;x;~string|table", {}):find("x is table", 1, true))
  assert(hook(2, "n;f.tl:3:4;n;~integer", 1.5) == 1.5 and hook(2, "n;f.tl:3:4;n;~integer", "s") == "s")
  assert(refused("n;f.tl:3:4;n;~integer", 3):find("n is integer", 1, true))
  assert(hook(2, "n;f.tl:3:4;x;string|nil", nil) == nil)
  assert(refused("n;f.tl:3:4;x;string|nil", 5):find("x is integer", 1, true))
  assert(hook(2, "n;f.tl:3:4;t.a;table", {}) ~= nil)
  assert(refused("n;f.tl:3:4;t.a;table", "s"):find("t.a is string", 1, true))
  assert(hook(2, "n;f.tl:3:4;n;integer", 3) == 3)
  assert(refused("n;f.tl:3:4;n;integer", 1.5):find("n is float", 1, true))
  assert(hook(2, "n;f.tl:3:4;n;number", 1.5) == 1.5 and hook(2, "n;f.tl:3:4;n;number", 2) == 2)
  assert(hook(2, "n;f.tl:3:4;n;nil", nil) == nil)
  assert(refused("n;f.tl:3:4;n;nil", 0):find("n is integer", 1, true))
  assert(refused("n;a%3Bb.tl:1:2;x;~nil", nil):find("fact violated at a;b.tl:1:2", 1, true), "an escaped file name")
  -- A spec that does not parse checks nothing, and answers the value.
  assert(hook(2, "n;broken", 7) == 7)
end

--- Every shape of read the checker narrows, in every position the code
--- generator must keep valid Lua in. `run` answers the same list checked
--- and not.
local valid_source = table.concat({
  "local record Box",
  "  name: string | nil",
  "  count: number | nil",
  "  items: {string} | nil",
  "end",
  "global shared: string | nil",
  "local function run(x: string | nil, b: Box, v: string | number | nil, a: any): {string}",
  "  local out: {string} = {}",
  "  local n = 0",
  "  if x then",
  "    n = n + 1",
  "    x:upper()",
  "    out[#out + 1] = x:upper()",
  "    out[#out + 1] = x .. \"!\"",
  "  end",
  "  if x ~= nil then",
  "    out[#out + 1] = \"neq\" .. x",
  "  end",
  "  local name, items, count = b.name, b.items, b.count",
  "  if name then",
  "    n = n + 1",
  "    name:upper()",
  "    out[#out + 1] = name",
  "    out[#out + 1] = name and name or \"unreachable\"",
  "    local both = { name, name }",
  "    out[#out + 1] = tostring(both[2])",
  "  end",
  "  if items then",
  "    out[#out + 1] = tostring(#items)",
  "    for _, item in ipairs(items) do out[#out + 1] = item end",
  "  end",
  "  if count and count > 1 then",
  "    out[#out + 1] = tostring(count + 1)",
  "  end",
  "  if v is string then",
  "    out[#out + 1] = v:lower()",
  "  elseif v is number then",
  "    out[#out + 1] = tostring(v + 1)",
  "  end",
  "  if type(a) == \"string\" then",
  "    out[#out + 1] = a",
  "  end",
  "  local copy = shared",
  "  if copy then",
  "    out[#out + 1] = copy",
  "  end",
  "  if x then",
  "    local f = function(): string return x end",
  "    out[#out + 1] = f()",
  "  end",
  "  b.name = b.name or \"set\"",
  "  return out",
  "end",
  "local function strict(x: string | nil): string",
  "  assert(x, \"need x\")",
  "  return x",
  "end",
  "local function varargs(first: string | nil, ...: string): string",
  "  if first then",
  "    return first .. select(\"#\", ...) .. (...)",
  "  end",
  "  return \"\"",
  "end",
  "return { run = run, strict = strict, varargs = varargs, set_shared = function(s: string | nil) shared = s end }",
  "",
}, "\n")

local record Valid
  run: function(string | nil, {string:any}, any, any): {string}
  strict: function(string | nil): string
  varargs: function(string | nil, string...): string
  set_shared: function(string | nil)
end

local function describe(list: {string}): string
  return table.concat(list, ",")
end

--- The inputs every case of `run` is given: the narrowed reads are true of
--- all of them, as the tests that guard them say.
local function cases(): {{any}}
  return {
    { "x", { name = "n", count = 2, items = { "i", "j" } }, "Str", "text" },
    { "x", { name = "n" }, 4, 7 },
    { nil, { count = 0 }, nil, nil },
    { nil, {}, "S", {} },
  }
end

local function test_valid_narrowed_reads_pass_and_answer_what_they_did()
  worker.install_checks()
  local code = compiled(valid_source, true)
  assert(count_of(code, "n;snippet:%d+:%d+;x;~nil") > 3, "no read of x was checked")
  assert(code:find("n;snippet:%d+:%d+;name;~nil", 1), "no read of a copy of a field was checked")
  assert(code:find("n;snippet:%d+:%d+;v;~nil|number", 1), "no `is` was checked")
  assert(code:find("n;snippet:%d+:%d+;a;string", 1), "no `type()` test was checked")
  assert(code:find("n;snippet:%d+:%d+;copy;~nil", 1), "no copy of a global was checked")
  local with = (assert(load(code, "=snippet", "t"))() as Valid)
  local without = (assert(load(compiled(valid_source, false), "=snippet", "t"))() as Valid)
  for _, shared in ipairs({ "g", "" }) do
    local value: string | nil = shared ~= "" and shared or nil
    with.set_shared(value)
    without.set_shared(value)
    -- Each run is given cases of its own: `run` writes the box it is given.
    local given, fresh = cases(), cases()
    for i, case in ipairs(given) do
      local checked_out = describe(with.run(case[1] as string, case[2] as {string:any}, case[3], case[4]))
      local other = fresh[i]
      local plain_out = describe(without.run(other[1] as string, other[2] as {string:any}, other[3], other[4]))
      assert(checked_out == plain_out, checked_out .. " against " .. plain_out)
    end
  end
  assert(with.varargs("a", "b", "c") == without.varargs("a", "b", "c"), "a vararg was changed by a check")
  assert(with.varargs(nil) == "")
  assert(with.strict("v") == "v" and without.strict("v") == "v")
end

--- A place narrowed by the type of a value assigned or declared with is not
--- checked itself (checker/tl.tl's TODO at the read of a variable): `f() or
--- f()` is a `string` that is nil here, as is an optional parameter. A test
--- that follows takes out only what the type before named.
local function test_a_place_narrowed_by_an_assigned_value_is_not_checked()
  local source = table.concat({
    "local function f(): string | nil return nil end",
    "local function g(opts?: {string:string}): string | nil",
    "  local why: string | nil = f()",
    "  why = f() or f()",
    "  local given: any = opts",
    "  if why ~= nil and given ~= nil then",
    "    return why",
    "  end",
    "  return nil",
    "end",
    "return g",
    "",
  }, "\n")
  worker.install_checks()
  local code = compiled(source, true)
  assert(not code:find("if [^\n]*n;snippet"), "a read narrowed by a value was checked: " .. code)
  assert(not code:find(";given;", 1, true), code)
  assert(not code:find("n;snippet", 1, true), "the test took out no nil the type before named: " .. code)
  local g = assert(load(code, "=snippet", "t"))() as function(): any
  assert(g() == nil, "the read of nil was refused")
end

--- A test takes out what it tests, not the kinds the declared type leaves: a
--- nil a map read gives a `string | R`, or a float given an `integer |
--- string`, passes both branches of an `is`.
local function test_what_a_test_leaves_of_the_declared_type_is_not_checked()
  local source = table.concat({
    "local record R end",
    "local function f(v: string | R): string",
    "  if v is string then",
    "    return v",
    "  else",
    "    return tostring(v)",
    "  end",
    "end",
    "local function g(w: integer | string): string",
    "  if w is string then",
    "    return w",
    "  else",
    "    return tostring(w)",
    "  end",
    "end",
    "return { f = f, g = g }",
    "",
  }, "\n")
  worker.install_checks()
  local code = compiled(source, true)
  assert(code:find(";v;~", 1, true) and code:find(";w;~", 1, true), code)
  local fixture = assert(load(code, "=snippet", "t"))() as {string:function(any): any}
  assert(fixture.f(nil) == "nil", "a nil for `string | R`")
  assert(fixture.f("s") == "s" and fixture.f({}) ~= nil)
  assert(fixture.g(1.5) == "1.5", "a float for `integer | string`")
  assert(fixture.g(2) == "2" and fixture.g("t") == "t")
end

--- A test on a place an enclosing test narrowed keeps the enclosing fact.
local function test_a_test_inside_a_narrowing_is_checked()
  local source = table.concat({
    "local record R end",
    "local function mk(): R | nil return {} end",
    "local function a(x: string | nil): string",
    "  assert(x)",
    "  if x ~= nil then",
    "    return x",
    "  end",
    "  return \"\"",
    "end",
    "local function b(x: string | nil, y: string | nil): string",
    "  if x ~= nil then",
    "    return x",
    "  elseif y ~= nil then",
    "    return y",
    "  end",
    "  return \"\"",
    "end",
    "local function c(): string",
    "  local s: R | nil = mk()",
    "  if s then",
    "    return tostring(s)",
    "  end",
    "  return \"\"",
    "end",
    "return { a = a, b = b, c = c }",
    "",
  }, "\n")
  local code = compiled(source, true)
  assert(count_of(code, "return[^\n]*;x;~nil") >= 2, "the reads of x after assert and ~= nil: " .. code)
  assert(code:find("return[^\n]*;y;~nil"), "the read of y after elseif: " .. code)
end

--- A place a test narrowed again after an assignment, or a `local x = x`, is
--- checked as it was before the entry was reused.
local function test_a_test_after_a_widening_is_checked()
  local source = table.concat({
    "local function g(): string | nil return \"g\" end",
    "local function a(x: string | nil): string",
    "  if x then",
    "    x = g()",
    "    if not x then return \"\" end",
    "    return x",
    "  end",
    "  return \"\"",
    "end",
    "local function b(y: string | nil): string",
    "  local y = y",
    "  if not y then return \"\" end",
    "  return y",
    "end",
    "return { a = a, b = b }",
    "",
  }, "\n")
  local code = compiled(source, true)
  assert(code:find("return[^\n]*;x;~nil"), "the read of x after the early return: " .. code)
  assert(code:find("return[^\n]*;y;~nil"), "the read of a local y = y: " .. code)
end

--- An assignment ends what a test said of the place: `known` is a `R` again
--- after `known = {}`, however the early return narrowed it, and the read
--- is not checked against the old fact.
local function test_an_assignment_ends_the_fact_of_an_earlier_test()
  local source = table.concat({
    "local record R",
    "  n: integer",
    "end",
    "local function f(seen: {integer:R}, place: integer): R",
    "  local known = seen[place]",
    "  if known ~= nil then return known end",
    "  known = { n = 1 }",
    "  seen[place] = known",
    "  return known",
    "end",
    "return f",
    "",
  }, "\n")
  worker.install_checks()
  local code = compiled(source, true)
  assert(not code:find(";known;", 1, true), code)
  local f = assert(load(code, "=snippet", "t"))() as function({any}, integer): any
  assert(f({}, 1) ~= nil)
end

--- A negated `is`, or the else branch of one, never tests nil: a place a value
--- narrowed that holds nil anyway (a map read the checker types as its value
--- type) passes both.
local function test_a_negated_is_does_not_take_out_nil()
  local source = table.concat({
    "local store: {string: string | integer} = {}",
    "local function missing(): string | integer return store[\"missing\"] end",
    "local function k(x: string | integer | nil): string",
    "  x = missing()",
    "  if not (x is integer) then return tostring(x) end",
    "  return \"integer\"",
    "end",
    "local function m(x: string | integer | nil): string",
    "  x = missing()",
    "  if x is string then return x end",
    "  return tostring(x)",
    "end",
    "return { k = k, m = m }",
    "",
  }, "\n")
  worker.install_checks()
  local fixture = assert(load(compiled(source, true), "=snippet", "t"))() as {string:function(any): any}
  assert(fixture.k(nil) == "nil", "`not (x is integer)` of a nil")
  assert(fixture.m(nil) == "nil", "the else branch of `x is string` of a nil")
end

--- Without the hook a checked compile still runs, and checks nothing: the
--- `select` the code falls back to answers the value.
local function test_a_chunk_without_the_hook_answers_its_values()
  local env = { select = select, tostring = tostring, type = type, assert = unchecked, ipairs = ipairs,
    setmetatable = setmetatable }
  local chunk = assert(load(compiled(lie_source, true), "=snippet", "t", env as {string:any}))
  local fixture = chunk() as Raising
  assert(fixture.read(nil) == nil, "the read answers the nil it was given")
end

--- A compile without the option is the Lua it always was: no hook, the
--- same lines and the text a read has always been written as.
local plain_expected = table.concat({
  "local record Pair",
  "  first: string | nil",
  "end",
  "local function show(p: Pair, x: string | nil): string",
  "  if x then",
  "    x:upper()",
  "    return x .. (p.first or \"\")",
  "  end",
  "  local first = p.first",
  "  if first then",
  "    return first",
  "  end",
  "  return \"\"",
  "end",
  "return show",
  "",
}, "\n")

local function test_a_compile_without_the_option_writes_no_check()
  local plain = compiled(plain_expected, false)
  assert(not plain:find("__cosmic_tc", 1, true), "an unchecked compile carries a check")
  assert(not plain:find("select", 1, true))
  local expected = table.concat({
    "",
    "",
    "",
    "local function show(p, x)",
    "   if x then",
    "      x:upper()",
    "      return x .. (p.first or \"\")",
    "   end",
    "   local first = p.first",
    "   if first then",
    "      return first",
    "   end",
    "   return \"\"",
    "end",
    "return show",
  }, "\n")
  assert(plain == expected, string.format("%q", plain))
  local with = compiled(plain_expected, true)
  assert(with:find("__cosmic_tc", 1, true))
  local function lines(text: string): integer
    return count_of(text, "\n")
  end
  assert(lines(with) == lines(plain), "the checks moved a line: " .. lines(plain) .. " against " .. lines(with))
  -- The same again: the option off is not a mode that depends on a compile before.
  assert(compiled(plain_expected, false) == plain)
end
