--- Tests of [`build.syntax_contracts`]: each program is read by the new checker and the breaches of each rule it says
--- are the ones the test names, and the programs that keep the rules get none, with the places where the checker's types
--- make the answer differ named in a test of their own.
local Rules = require("build.contract_rules")
local Fixture = require("build.syntax_typed_fixture")
local SyntaxContracts = require("build.syntax_contracts")
local Test = require("cosmic.test")

Test.policy{
  grants = {
    { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" },
    { path = "core/syscalls.h", letters = "r" }, { path = "core/process.h", letters = "r" }, { path = "core/socket.h", letters = "r" },
  },
}

local LOG_MODULES <const>: {string: string} = { ["cosmic.log"] = Fixture.LOG }

--- What the checker says of `body` after the prelude: its problems.
local function problems_of(body: string, given?: Rules.Exemptions, modules?: {string: string}): {string}
  return Fixture.port(Fixture.PRELUDE .. body, modules or LOG_MODULES, given).problems
end

--- Programs that breach a rule: the checker refuses each with `wanted` in its words.
local function breaches(wanted: string, bodies: {string})
  for _, body in ipairs(bodies) do
    local found = problems_of(body)
    assert(#found >= 1, "no breach found in:\n" .. body)
    local joined = table.concat(found, "\n")
    assert(joined:find(wanted, 1, true) ~= nil, "expected " .. wanted .. " in:\n" .. joined .. "\nof:\n" .. body)
  end
end

--- Programs that keep the rules: the checker finds nothing.
local function keeps(bodies: {string})
  for _, body in ipairs(bodies) do
    local found = problems_of(body)
    assert(#found == 0, table.concat(found, "\n") .. "\nin:\n" .. body)
  end
end

local function exempting(which: string, keys: {string}): Rules.Exemptions
  local out: Rules.Exemptions = { exempt = {}, parsing = {}, casts = {}, modes = {} }
  local named: mut {string: string} = which == "exempt" and out.exempt or which == "parsing" and out.parsing or
    which == "modes" and out.modes or out.casts
  for _, key in ipairs(keys) do
    named[key] = "a test's own exemption"
  end
  return out
end

local function test_a_dropped_error_slot_is_flagged_wherever_it_is_truncated()
  breaches("its error slot is dropped", {
    "local v = get() or 0\nuse(v)", "use(not put())", "if get() then use(1) end", "use(get() == 1)", "use(get(), 1)",
    "local v = get()\nuse(v)", "local v, w = get(), 1\nuse(v, w)", "use((get()))", "use({get()})", "use({1, get()})",
    "print(get())", "use(select(1, get()))", "use(1, get())", "lead(sget())", "maybe(get())",
    "local function va(_v: integer?, _why: string, ...: any) end\nva(get())",
  })
  breaches("its failure is ignored", {
    "put()", "get()", "do put() end", "local function f() put() end\nuse(f)", "use(function() put() end)",
    "if 1 > 0 then put() end", "for _ = 1, 2 do put() end", "while 1 < 0 do put() end",
  })
end

local function test_a_kept_error_slot_is_allowed()
  keeps({
    "local v, err = get()\nuse(v, err)", "local v: integer\nlocal err: string\nv, err = get()\nuse(v, err)",
    "use(assert(get()))", "local function f(): integer?, string return get() end\nuse(f)", "local _, _ = put()",
    "local ok, _ = put()\nuse(ok)", "complain(get())", "log:note(get())", "log.note(log, get())",
    "use(name() or 'y')", "use(not pair())", "name()", "pair()",
    "local function mk(): function(): boolean, string return put end\nlocal _, _ = mk()()",
  })
end

local function test_a_method_is_judged_by_the_function_the_checker_took_for_it()
  local record_source = "local record Obj\n  fetch: function(Obj): integer?, string\n  count: function(Obj): integer\nend\n" ..
    "local o: Obj = { fetch = function(_: Obj): integer?, string return nil, 'x' end," ..
    " count = function(_: Obj): integer return 1 end }\n"
  breaches("o:fetch: its failure is ignored", { record_source .. "o:fetch()" })
  breaches("o:fetch: its error slot is dropped", { record_source .. "use(o:fetch())", record_source .. "local v = o:fetch()\nuse(v)" })
  breaches("o.fetch: its failure is ignored", { record_source .. "o.fetch(o)" })
  keeps({ record_source .. "local a, b = o:fetch()\nuse(a, b)", record_source .. "o:count()\nuse(o:count())" })
  -- a chained call is judged by the answer of the one before it
  breaches("its failure is ignored", {
    "local function mk(): function(): boolean, string return put end\nmk()()",
  })
end

local function test_a_failure_carries_no_value()
  breaches("beside its reason", {
    "local function f(): integer?, string\n  local v, err = get()\n  if v == nil then return 0, err end\n" ..
      "  return v, ''\nend\nuse(f)",
    "local function f(): boolean, string\n  local ok, why = put()\n  return ok, why\nend\nuse(f)",
    "local function f(n: integer): integer?, string\n  if n > 0 then return n, nil end\n" ..
      "  return nil, 'not positive'\nend\nuse(f)",
  })
  keeps({
    "local function f(): integer?, string\n  local v, err = get()\n  if v == nil then return nil, err end\n" ..
      "  return v, ''\nend\nuse(f)",
    "local function f(): boolean, string\n  local ok, why = put()\n  if not ok then return false, why end\n" ..
      "  return true, ''\nend\nuse(f)",
    "local function f(): integer?, string\n  local function g(): integer, string return 1, 'two' end\n" ..
      "  use(g)\n  return get()\nend\nuse(f)",
  })
end

local function test_a_reason_is_exactly_a_string()
  breaches("a failure's reason is exactly a string", {
    "local function f(): string?, integer\n  return nil, 127\nend\nuse(f)",
    "local function f(): {string}?, integer | string\n  return nil, 'no'\nend\nuse(f)",
    "local function f(): string?, string?\n  return nil, 'no'\nend\nuse(f)",
  })
  keeps({
    "local function f(): boolean, integer\n  return true, 1\nend\nuse(f)",
    "local function f(): integer?, integer?\n  return nil, nil\nend\nuse(f)",
  })
end

local function test_a_failure_that_cannot_happen_is_not_declared()
  breaches("the declared failure never happens", {
    "local function f(n: integer): integer?, string\n  if n > 0 then return n, '' end\n  return 0, ''\nend\nuse(f)",
    "local function f(n: integer): integer?, string\n  return n + 1, ''\nend\nuse(f)",
  })
  keeps({
    "local function f(n: integer): integer?, string\n  if n > 0 then return n, '' end\n" ..
      "  return nil, 'not positive'\nend\nuse(f)",
    "local function f(): integer?, string\n  return get()\nend\nuse(f)",
  })
end

local function test_a_fallible_function_declares_exactly_two_results()
  breaches("nothing in a third", {
    "local function f(): integer?, string, integer\n  return nil, 'no', 2\nend\nuse(f)",
    "local function f(): boolean, string, integer\n  return false, 'no', 2\nend\nuse(f)",
    "local t = {}\nt.f = function(): integer?, string, integer\n  return nil, 'no', 2\nend\nuse(t)",
    "local function f(): integer?, string...\n  return nil, 'no', 'more'\nend\nuse(f)",
    "local record R end\nfunction R.f(): integer?, string, integer\n  return nil, 'no', 2\nend\nuse(R)",
  })
end

local function test_an_exempt_function_is_not_held_to_the_return_rules()
  local source = "local function f(): integer?, string\n  return 1, 'why'\nend\nuse(f)"
  breaches("beside its reason", { source })
  local found = problems_of(source, exempting("exempt", { "x.tl:f" }))
  assert(#found == 0, table.concat(found, "\n"))
  local nested = "local function f()\n  local function g(): integer?, string return 1, 'x' end\n  use(g)\nend\nuse(f)"
  breaches("a failure answers nil beside its reason", { nested })
  assert(#problems_of(nested, exempting("exempt", { "x.tl:f.g" })) == 0)
end

local function test_a_quiet_records_method_may_stand_alone_and_a_record_named_like_it_may_not()
  local source = 'local Log = require("cosmic.log")\nlocal logger = Log.new()\n'
  keeps({ source .. "logger:say('hello')", source .. "do logger:say('trouble') end" })
  breaches("its error slot is dropped", { source .. "use(logger:say('hello'))" })
  breaches("its failure is ignored", {
    source .. "logger:flush()",
    "local record Logger\n  say: function(Logger, string): boolean, string\nend\n" ..
      "local logger: Logger = { say = function(_: Logger, _l: string): boolean, string return true, '' end }\n" ..
      "logger:say('hello')",
  })
end

local function test_a_reason_is_never_read_for_what_it_says()
  local read = "a failure's reason is read for what it says"
  local bound = "local v, err = get()\n"
  breaches(read, {
    bound .. "use(v, err:find('x'))", bound .. "use(v, err:match('x'))", bound .. "use(v, string.find(err, 'x'))",
    bound .. "use(v, err == 'timeout')", bound .. "use(v, err ~= 'timeout')", bound .. "use(v, (err):find('x'))",
    bound .. "use(v, tostring(err):find('x'))", bound .. "use(v, err:lower():find('x'))",
    bound .. "use(v, tostring(err) == 'x')", bound .. "local why = err\nuse(v, why:find('x'))",
    bound .. "local why = err\nlocal again = why\nuse(v, again == 'x')", bound .. "local a, why = v, err\nuse(a, why:find('x'))",
    bound .. "local why: string\nwhy = tostring(err)\nuse(v, why:sub(1, 2))",
    "local TIMEOUT <const> = 'timeout'\n" .. bound .. "use(v, err == TIMEOUT)", bound .. "use(v, err < 'm')",
    "local v, err = get()\ndo local err = name() use(err:find('x')) end\nuse(v, err:find('x'))",
    "local v, err = get()\nlocal err2 = err:find('x')\nuse(v, err2)",
    "local v, err = get()\ndo local err = err:sub(1, 2) use(err) end\nuse(v)",
    "local v, err = get()\nif v == nil then\n  v, err = get()\nend\nuse(v, err:find('x'))",
    "local v: integer?\nlocal err = ''\nif name() == 'a' then\n  v, err = get()\nend\nuse(v, err:match('x'))",
    "local v, err = get()\nif v == nil then\n  err = name()\nend\nuse(v, err:find('x'))",
  })
  keeps({
    bound .. "use(v, err == '', err ~= '', '' == err)", bound .. "if err then use(v) end",
    bound .. "use(v, 'get: ' .. err, string.format('%s', err), #err > 0)", bound .. "complain(v, err)",
    bound .. "use(v, err:gsub('\\n', ' '))", bound .. "use(v, tostring(err) .. '!', err:lower())",
    bound .. "local why = 'get: ' .. err\nuse(v, why:find('x'))", bound .. "local why = err\nwhy = name()\nuse(v, why:find('x'))",
    "local s = name()\nuse(s:find('x'))",
    "local function two(): string, string return 'a', 'b' end\nlocal a, b = two()\nuse(a, b:find('b'))",
    "local v, err = get()\nerr = name()\nuse(v, err:find('x'))",
    "local v, err = get()\nuse(v, function(err: string): boolean\n  return err:find('x') ~= nil\nend)",
    "local v, err = get()\nuse(v)\nfor _, err in ipairs({'a'}) do use(err:find('a')) end",
    "local err = name()\ndo local v, err = get() use(v, err) end\nuse(err:find('x'))",
    "local err = name()\ndo\n  local v, err2 = get()\n  do\n    local err: string\n    v, err = get()\n    use(err2)\n  end\n" ..
      "  use(v)\nend\nuse(err:find('x'))",
    "local err = name()\nif name() == 'a' then\n  err = name()\nend\nuse(err:find('x'))",
    "local err = name()\ndo local v, err = get() use(v, err) end\nlocal e = err:find('x')\nuse(e)",
    "local Poll = { TIMEOUT = 'timed out', CANCELLED = 'cancelled', OTHER = 'x' }\n" .. bound ..
      "use(v, err == Poll.TIMEOUT, Poll.CANCELLED ~= err)",
  })
  breaches(read, { "local Poll = { TIMEOUT = 'timed out', CANCELLED = 'cancelled', OTHER = 'x' }\n" .. bound ..
      "use(v, err == Poll.OTHER)" })
  -- a reason reached without a name drops its slot
  breaches("its error slot is dropped", { "use(select(2, get()) == 'none')" })
  local source = "local function f()\n  local v, err = get()\n  use(v, err:find('x'))\nend\nuse(f)"
  assert(#problems_of(source, exempting("parsing", { "x.tl:f" })) == 0)
  local nested = "local function f()\n  local function g()\n    local v, err = get()\n    use(v, err:find('x'))\n  end\n" ..
    "  use(g)\nend\nuse(f)"
  assert(#problems_of(nested, exempting("parsing", { "x.tl:f.g" })) == 0)
end

local function test_a_cast_is_flagged_where_no_function_may_cast()
  local cast = "a cast tells the checker what it could not prove"
  breaches("f: " .. cast, { "local function f(v: any): integer return v as integer end\nuse(f)",
    "local f = function(v: any): integer return v as integer end\nuse(f)" })
  breaches("the top level: " .. cast, { "local t: {any} = {}\nuse(t[1] as string)", "use({} as {string})",
    "local other: any = select(1, ...)\nuse(other as {string})" })
  breaches("r.g: " .. cast, { "local r: {string: function(any): integer} = {}\nr.g = function(v: any): integer return v as integer end" })
  breaches("t.g: " .. cast, { "local t = { g = function(v: any): integer return v as integer end }\nuse(t)" })
  breaches("R.m: " .. cast, { "local record R end\nfunction R.m(v: any): integer return v as integer end" })
  breaches("f.g: " .. cast, { "local function f()\n  local function g(v: any): integer return v as integer end\n  use(g)\nend\nuse(f)" })
  keeps({
    "local t: {any} = {}\nlocal v = t[1]\nif v is string then use(v) end",
    "local extra: any = select(2, ...)\nuse(extra as {string})",
    "local extra: any = select(2, ...)\nif extra is {string} then use(1) else use((extra) as {string}) end",
  })
  breaches("f: " .. cast, { "local extra: any = select(2, ...)\nlocal function f(): {string} return extra as {string} end\nuse(f)" })
  local source = "local function f(v: any): integer return v as integer end\nlocal g = function(v: any): string return v as string end\nuse(f, g)"
  local one = problems_of(source, exempting("casts", { "x.tl:f" }))
  assert(#one == 1 and one[1]:find("g: " .. cast, 1, true) ~= nil, table.concat(one, "\n"))
  assert(#problems_of(source, exempting("casts", { "x.tl:f", "x.tl:g" })) == 0)
end

local function test_an_exemption_no_check_needs_is_refused()
  local unused = "which no longer needs it"
  for _, which in ipairs({ "casts", "parsing", "exempt", "modes" }) do
    local found = problems_of("use(1)", exempting(which, { "x.tl:gone" }))
    assert(#found == 1 and found[1]:find("contracts." .. which .. " names x.tl:gone, " .. unused, 1, true), table.concat(found, "\n"))
    local stubbed = problems_of("use(1)", exempting(which, { "build/importer.tl:generate" }))
    assert(#stubbed == 1 and stubbed[1]:find("names build/importer.tl:generate", 1, true), table.concat(stubbed, "\n"))
  end
end

local function test_a_type_repeating_its_module_is_flagged()
  local stutters = "a type repeats its module's name"
  breaches("Zip.ZipReader: " .. stutters .. ", which every use already says; call it Zip.Reader", {
    "local record Zip\n  record ZipReader\n    n: integer\n  end\nend\nreturn Zip",
  })
  breaches("Zip.Zip: " .. stutters, { "local record Zip\n  enum Zip\n    \"a\"\n  end\nend\nreturn Zip" })
  breaches("zip.ZipKind: " .. stutters, { "local record zip\n  type ZipKind = string\nend\nreturn zip" })
  breaches("Zip.Entry.ZipKind: " .. stutters, {
    "local record Zip\n  record Entry\n    enum ZipKind\n      'a'\n    end\n  end\nend\nreturn Zip" })
  breaches("Sqlite.SQLiteHandle: " .. stutters, { "local record Sqlite\n  record SQLiteHandle\n    n: integer\n  end\nend\nreturn Sqlite" })
  breaches("layout.LayoutRule: " .. stutters, {
    "local record Layout\n  record LayoutRule\n    n: integer\n  end\nend\nlocal layout: Layout = {}\nreturn layout" })
  keeps({
    "local record Log\n  record Logger\n    n: integer\n  end\n  record Reader\n    n: integer\n  end\n  LogLevel: integer\nend\nreturn Log",
    "local record Zip\n  record ZipReader\n    n: integer\n  end\nend\nlocal record Other\nend\nuse(Zip)\nreturn Other",
  })
end

local function test_a_string_mode_is_flagged_and_a_string_that_is_no_mode_is_allowed()
  local modal = "is a closed set of modes"
  local options = "local record Options\n  links: string\nend\n"
  breaches("Options.links: a string compared with \"create\", \"skip\" " .. modal, {
    options .. "local function f(o: Options)\n  if o.links == 'skip' then use(1) elseif o.links ~= 'create' then use(2) end\nend\nuse(f)",
    options .. "local function f(o: Options)\n  local mode = o.links or 'skip'\n  if mode == 'create' then use(1) end\nend\nuse(f)",
    "local record Options\n  links: string?\nend\nlocal function f(o: Options)\n" ..
      "  if o.links == 'skip' or o.links == 'create' then use(1) end\nend\nuse(f)",
    options .. "local function f(o: Options)\n  local m: string\n  m = o.links\n  if m == 'skip' or m == 'create' then use(1) end\nend\nuse(f)",
  })
  breaches("R.WriterOptions.method: a string compared with \"deflate\", \"store\" " .. modal, {
    "local record R\n  record WriterOptions\n    method: string\n  end\nend\n" ..
      "local function g(name: string)\n  if name == 'store' then use(1) elseif name == 'deflate' then use(2) end\nend\n" ..
      "local function f(o: R.WriterOptions)\n  g(o.method)\nend\nuse(f)",
  })
  keeps({
    options .. "local function f(o: Options)\n  if o.links == 'create' or o.links == '' then use(1) end\nend\nuse(f)",
    "local enum Links\n  'skip'\n  'create'\nend\nlocal record Options\n  links: Links\nend\n" ..
      "local function f(o: Options)\n  if o.links == 'skip' or o.links == 'create' then use(1) end\nend\nuse(f)",
    "local record Options\n  path: string\nend\nlocal function f(o: Options)\n  use(o.path .. '/x')\nend\nuse(f)",
    "local record Entry\n  kind: string\nend\nlocal function f(e: Entry)\n  if e.kind == 'a' or e.kind == 'b' then use(1) end\nend\nuse(f)",
    "local record Options\n  kind: string\nend\nlocal record Other\n  kind: string\nend\n" ..
      "local function f(o: Options, e: Other)\n  if e.kind == 'a' or e.kind == 'b' then use(o.kind) end\nend\nuse(f)",
    options .. "local function f(o: Options)\n  local m = o.links\n  if m == 'skip' then use(1) end\nend\n" ..
      "local function g(m: string)\n  if m == 'a' or m == 'b' then use(2) end\nend\nuse(f, g)",
    options .. "local function f(o: Options)\n  local m = o.links\n  if m == 'skip' then use(1) end\n" ..
      "  local m2 = m\n  local m = 'x'\n  if m == 'a' or m == 'b' then use(m2) end\nend\nuse(f)",
  })
  local source = options .. "local function f(o: Options)\n  if o.links == 'skip' or o.links == 'create' then use(1) end\nend\nuse(f)"
  assert(#problems_of(source, exempting("modes", { "x.tl:Options.links" })) == 0)
end

local function test_an_exported_tuple_is_flagged_and_a_single_result_or_failure_pair_is_allowed()
  local tuple = "an exported function answers one result"
  breaches("M.split: " .. tuple, { "local record M end\nfunction M.split(): string, string\n  return 'a', 'b'\nend\nreturn M" })
  breaches("M.f: " .. tuple, {
    "local record M\n  f: function(): string, string\nend\nlocal function f(): string, string return 'a', 'b' end\nM.f = f\nreturn M",
  })
  breaches(tuple, {
    "local record M end\nfunction M.pair(): boolean, integer\n  return true, 1\nend\nreturn M",
    "local record M end\nfunction M.all(): string...\n  return 'a', 'b'\nend\nreturn M",
    "local record M end\nfunction M.twice<T>(x: T): T, T\n  return x, x\nend\nreturn M",
  })
  breaches("M.R.pair: " .. tuple, {
    "local record M\n  record R\n    n: integer\n    pair: function(R): integer, integer\n  end\nend\nreturn M",
  })
  keeps({
    "local record M end\nfunction M.one(): string\n  return 'a'\nend\nfunction M.read(): string?, string\n  return sget()\nend\n" ..
      "function M.write(): boolean, string\n  return put()\nend\nreturn M",
    "local record M end\nlocal function split(): string, string\n  return 'a', 'b'\nend\nfunction M.first(): string\n" ..
      "  local a, _ = split()\n  return a\nend\nreturn M",
  })
  assert(#problems_of("local record M end\nfunction M.split(): string, string\n  return 'a', 'b'\nend\nreturn M",
    exempting("exempt", { "x.tl:M.split" })) == 0)
end

local function test_every_rule_judged_a_place_in_the_programs_it_read()
  local source = Fixture.PRELUDE .. table.concat({
    "local record Options\n  mode: string\nend",
    "get()",
    "local function f(o: Options): integer?, string",
    "  local v, err = get()",
    "  if o.mode == 'a' or o.mode == 'b' then use(err:find('x')) end",
    "  use(v as any)",
    "  return nil, 'no'",
    "end",
    "local record Zip\n  record ZipReader end\n  open: function(): string, string\nend",
    "function Zip.flag(): boolean\n  return true\nend",
    "return Zip",
  }, "\n")
  local said = Fixture.port(source, LOG_MODULES)
  for _, rule in ipairs(SyntaxContracts.rules) do
    assert((said.sites[rule] or 0) > 0, "the rule " .. rule .. " judged nothing")
  end
end

--- The bindings of C are typed from the declarations the build derives from their headers, so the rules judge their calls as
--- any other: a dropped slot, a reason parsed, a bare boolean over a binding (rule 11), and a stand-in for a binding.
local function test_the_calls_of_a_binding_of_c_are_judged_as_any_others_are()
  local sys = "local sys = require('cosmic.sys')\n"
  breaches("sys.unlink: its failure is ignored", { sys .. "sys.unlink('x')" })
  breaches("its error slot is dropped", {
    sys .. "local v = sys.stat('x')\nuse(v)", sys .. "use(not sys.unlink('x'))", sys .. "use(sys.stat('x'), 1)",
  })
  breaches("a failure's reason is read for what it says", {
    sys .. "local v, err = sys.stat('x')\nuse(v, err:find('x'))", sys .. "local ok, err = sys.unlink('x')\nuse(ok, err == 'gone')",
  })
  keeps({
    sys .. "local v, err = sys.stat('x')\nuse(v, err)", sys .. "local _, _ = sys.unlink('x')",
    sys .. "local ok, err, errno = sys.unlink('x')\nuse(ok, err, errno)",
  })
end

--- A table of C bindings the program holds as a module that declares no table is told, not dropped from the contract:
--- its calls would go unjudged without a word. A program without the module judges nothing of it, and says nothing.
local function test_a_binding_the_program_holds_without_a_table_is_told_by_name()
  local lost = Fixture.port(Fixture.PRELUDE .. "local sys = require('cosmic.sys')\nreturn sys\n",
    { ["cosmic.sys"] = "local n: integer = 1\nreturn n\n" }, nil)
  local told = table.concat(lost.problems, "\n")
  assert(told:find("cosmic.sys is a table of C bindings, but the program holds", 1, true) ~= nil and
      told:find("declares no table", 1, true) ~= nil, told)
  local absent = Fixture.port(Fixture.PRELUDE .. "local record M end\nreturn M\n", {}, nil)
  assert(#absent.problems == 0, table.concat(absent.problems, "\n"))
end

--- A declaration that declares itself a binding (`--- @kind binding`) is held to the contract as the generated tables are:
--- an exported function that answers a bare boolean over one of its calls (rule 11) is a breach through it and none
--- through a declaration without the line.
local function test_a_declaration_that_declares_itself_a_binding_is_held_to_the_contract()
  local declaration = "local record Drv\n  poke: function(string): boolean, string, integer\nend\nreturn Drv\n"
  local call = "local drv = require('my.drv')\nlocal record M end\nfunction M.rm(p: string): boolean\n" ..
    "  local ok, _ = drv.poke(p)\n  return ok\nend\nreturn M\n"
  local plain = problems_of(call, nil, { ["my.drv"] = declaration })
  assert(#plain == 0, table.concat(plain, "\n"))
  local held = problems_of(call, nil, { ["my.drv"] = "--- @kind binding\n" .. declaration })
  assert(table.concat(held, "\n"):find("calls my.drv.poke itself and answers a bare boolean", 1, true) ~= nil,
    table.concat(held, "\n"))
end

local function test_an_exported_bare_boolean_over_a_binding_is_flagged()
  local sys = "local sys = require('cosmic.sys')\nlocal record M end\n"
  local bare = "calls cosmic.sys.unlink itself and answers a bare boolean"
  breaches("M.rm: " .. bare, {
    sys .. "function M.rm(p: string): boolean\n  local ok, _ = sys.unlink(p)\n  return ok\nend\nreturn M",
    "local sys = require('cosmic.sys')\nlocal record M\n  rm: function(string): boolean\nend\n" ..
      "function M.rm(p: string): boolean\n  local ok, _ = sys.unlink(p)\n  return ok\nend\nreturn M",
  })
  -- a local function stored into the export (a module that returns a constructor with no declaration is `export_not_declared`)
  breaches(bare, {
    sys .. "local function rm(p: string): boolean\n  local ok, _ = sys.unlink(p)\n  return ok\nend\n" ..
      "local record N\n  rm: function(string): boolean\nend\nlocal n: N = { rm = rm }\nuse(M)\nreturn n",
  })
  keeps({
    sys .. "function M.rm(p: string): boolean, string\n  local ok, err = sys.unlink(p)\n  if not ok then return false, err end\n" ..
      "  return true, ''\nend\nreturn M",
    -- a binding called from a function nested in it is that function's
    sys .. "function M.later(p: string): boolean\n  use(function(): boolean\n    local ok, _ = sys.unlink(p)\n    return ok\n  end)\n" ..
      "  return true\nend\nreturn M",
    -- a local wrapper is not the module's answer
    sys .. "local function rm(p: string): boolean\n  local ok, _ = sys.unlink(p)\n  return ok\nend\nuse(rm)\nreturn M",
  })
  local exempt = sys .. "function M.rm(p: string): boolean\n  local ok, _ = sys.unlink(p)\n  return ok\nend\nreturn M"
  assert(#problems_of(exempt, exempting("exempt", { "x.tl:M.rm" })) == 0)
end

local function test_the_raw_process_table_is_held_as_the_syscall_table_is()
  local process = "local process = require('cosmic.internal.process')\n"
  keeps({
    process .. "local spawn = process.spawn\nprocess.spawn = function(path: string, argv: {string}, environment: {string:string}?,\n" ..
      "    cwd: string?, stdin: integer?, stdout: integer?,\n" ..
      "    stderr: integer?, process_group: boolean, fds?: {integer:integer},\n" ..
      "    sandbox?: process.Sandbox, credentials?: process.Credentials): integer?, string, integer\n" ..
      "  local pid, trouble, errno = spawn(path, argv, environment, cwd, stdin, stdout,\n" ..
      "    stderr, process_group, fds, sandbox, credentials)\n  return pid, trouble, errno\nend",
  })
  breaches("M.adopt: calls cosmic.internal.process.subreaper itself and answers a bare boolean", {
    process .. "local record M end\nfunction M.adopt(): boolean\n  local ok, _ = process.subreaper()\n  return ok\nend\nreturn M",
  })
end

--- A function stored into a field of a table of C bindings keeps the binding's third slot, known by the type of the field's
--- owner whatever the owner is called, and a table of our own does not.
local function test_a_function_stored_into_a_table_of_c_bindings_keeps_the_bindings_third_slot()
  local third = "nothing in a third"
  local sys = "local sys = require('cosmic.sys')\nlocal unlink = sys.unlink\n"
  local stand_in = "function(p: string): boolean, string, integer\n"
  keeps({
    sys .. "sys.unlink = " .. stand_in .. "  return unlink(p)\nend\n",
    -- one that hands the binding's whole answer on as three names is not read for rule 2 either
    sys .. "sys.unlink = " .. stand_in .. "  local a, b, c = unlink(p)\n  return a, b, c\nend\n",
  })
  breaches(third, { "local t: {string: function(string): boolean, string, integer} = {}\nt.unlink = function(p: string): boolean, string, integer\n" ..
      "  return false, p, 1\nend\nuse(t)\n" })
end

--- Deliberate difference of what a function is: an overloaded callee is judged by the overload taken (but for `assert`, which
--- answers what it is given).
local function test_an_overloaded_callee_is_judged_by_the_overload_taken_but_assert_is_never_a_failure_of_its_own()
  local found = Fixture.port(Fixture.PRELUDE .. "assert(put())\nassert(get())\n", LOG_MODULES)
  assert(#found.problems == 0, table.concat(found.problems, "\n"))
end

local ONE_RESULT <const> = "an exported function answers one result"

--- The first problem of `found`, "" where there is none.
local function first_problem(found: Fixture.Said): string
  return found.problems[1] or ""
end

--- What the port says of a module whose record `M` has the field `field` after `before`.
local function exported(before: string, field: string, modules?: {string: string}, given?: Rules.Exemptions): Fixture.Said
  return Fixture.port(Fixture.PRELUDE .. before .. "local record M\n  " .. field .. "\nend\nreturn M\n", modules or LOG_MODULES, given)
end

--- A field of a record `M`, and the text before the record that its type names.
local record Form
  before: string
  field: string
end

--- A field of a function type is a function the module exports, written as the type or as a name that stands for it: a type
--- of the module, of the record, one that names another, or one of another module's record.
local function test_an_exported_field_is_judged_by_its_function_type_however_the_type_is_written()
  local inline = exported("", "spread: function(string): string, string")
  assert(#inline.problems == 1 and first_problem(inline):find("M.spread: " .. ONE_RESULT, 1, true) ~= nil,
    table.concat(inline.problems, "\n"))
  local named: {Form} = {
    { before = "local type Spread = function(string): string, string\n", field = "spread: Spread" },
    { before = "local type Spread = function(string): string, string\nlocal type Other = Spread\n", field = "spread: Other" },
    { before = "", field = "type Spread = function(string): string, string\n  spread: Spread" },
    { before = "", field = "type Spread = function(string): string...\n  spread: Spread" },
  }
  for _, form in ipairs(named) do
    local found = exported(form.before, form.field)
    assert(#found.problems == 1 and first_problem(found):find("M.spread: " .. ONE_RESULT, 1, true) ~= nil,
      form.field .. "\n" .. table.concat(found.problems, "\n"))
  end
  local modules: {string: string} = {
    ["cosmic.log"] = Fixture.LOG,
    spreads = "local record Spreads\n  type Spread = function(string): string, string\nend\nreturn Spreads\n",
  }
  local imported = exported("local type Spreads = require('spreads')\n", "spread: Spreads.Spread", modules)
  assert(#imported.problems == 1 and first_problem(imported):find("M.spread: " .. ONE_RESULT, 1, true) ~= nil,
    table.concat(imported.problems, "\n"))
  -- the exemption of the field covers it, and is used
  local exempt = exported("local type Spread = function(string): string, string\n", "spread: Spread", nil,
    exempting("exempt", { "x.tl:M.spread" }))
  assert(#exempt.problems == 0 and #exempt.used == 1, table.concat(exempt.problems, "\n") .. tostring(#exempt.used))
end

local function test_an_exported_field_that_may_be_any_of_several_function_types_is_judged_by_each()
  local before = "local type Spread = function(string): string, string\nlocal type One = function(string): string\n"
  for _, field in ipairs({ "either: Spread | One", "either: One | Spread" }) do
    local found = exported(before, field)
    assert(#found.problems == 1 and first_problem(found):find("M.either: " .. ONE_RESULT, 1, true) ~= nil,
      field .. "\n" .. table.concat(found.problems, "\n"))
  end
  -- two members that answer several results are one problem
  local twice = exported(before .. "local type Third = function(string): integer, integer\n", "either: Spread | Third")
  assert(#twice.problems == 1, table.concat(twice.problems, "\n"))
  local kept = exported(before .. "local type Other = function(string): string?, string\n", "either: One | Other")
  assert(#kept.problems == 0, table.concat(kept.problems, "\n"))
  -- a function of one of them is judged as a function of its own
  assert(#exported(before, "either?: Spread").problems == 1)
end

local function test_an_exported_field_of_a_function_type_that_answers_one_result_or_a_failure_is_allowed_by_any_name()
  local allowed: {Form} = {
    { before = "local type One = function(string): string\n", field = "one: One" },
    { before = "local type Pair = function(string): string?, string\n", field = "pair: Pair" },
    { before = "local type Effect = function(string): boolean, string\n", field = "effect: Effect" },
    { before = "local type Nothing = function(string)\n", field = "nothing: Nothing" },
    { before = "", field = "type Hint = function(string): string\n  hint: Hint" },
    -- a name that is no function type
    { before = "local record Other\n  n: integer\nend\n", field = "other: Other" },
    { before = "local type Names = {string}\n", field = "names: Names" },
    -- the function it answers is a value: its definition is judged where it is written, by the rules of any function
    { before = "local type Pair = function(): string, string\n", field = "make: function(): Pair" },
  }
  for _, form in ipairs(allowed) do
    local found = exported(form.before, form.field)
    assert(#found.problems == 0, form.field .. "\n" .. table.concat(found.problems, "\n"))
  end
  -- every rule judged the field: a place for rule 10 for each
  local judged = exported("local type One = function(string): string\n", "one: One")
  assert((judged.sites["exports"] or 0) == 1, tostring(judged.sites["exports"]))
end

--- A result typed by a binding of C's record is a fallible function's, and an `invalid` one (a type that failed to lower) is
--- taken for a type that admits nil.
local function test_a_result_typed_by_a_binding_of_c_admits_nil()
  keeps({ "local sys = require('cosmic.sys')\nlocal record M end\nfunction M.stat(p: string): sys.Stat?, string\n  return nil, p\nend\nreturn M" })
  local unknown = Fixture.port(Fixture.PRELUDE .. "local record M end\nfunction M.stat(p: string): Nowhere?, string\n  return nil, p\nend\nreturn M\n",
    LOG_MODULES)
  assert(#unknown.problems == 0, table.concat(unknown.problems, "\n"))
end

--- The corners of rules the first programs did not reach: each string method a reason is parsed with, a result that admits nil
--- as `any` does, every expression that cannot be nil, a callee whose last parameter is no string, and two problems on a line.
local function test_every_string_method_and_wrapper_a_reason_is_read_through_is_flagged()
  local read = "a failure's reason is read for what it says"
  local bound = "local v, err = get()\n"
  breaches(read, {
    bound .. "use(v, err:byte(1))", bound .. "use(v, err:gmatch('x'))", bound .. "use(v, err:upper():find('x'))",
    bound .. "use(v, err:sub(1, 2))", bound .. "use(v, string.sub(err, 1, 2))", bound .. "use(v, string.byte(err))",
  })
end

local function test_a_result_that_admits_nil_as_any_does_and_every_value_that_cannot_be_nil_are_judged()
  breaches("beside its reason", { "local function f(): any, string\n  return 1, 'x'\nend\nuse(f)" })
  local never = "the declared failure never happens"
  breaches(never, {
    "local function f(s: string): string?, string\n  return s .. 'x', ''\nend\nuse(f)",
    "local function f(n: integer): integer?, string\n  return -n, ''\nend\nuse(f)",
    "local function f(t: {string}): integer?, string\n  return #t, ''\nend\nuse(f)",
    "local function f(b: boolean): boolean?, string\n  return not b, ''\nend\nuse(f)",
    "local function f(n: integer): boolean?, string\n  return n < 2, ''\nend\nuse(f)",
    "local function f(): {string: string}?, string\n  local m: {string: string} = {}\n  return m, ''\nend\nuse(f)",
    "local function f(): {string}?, string\n  local a: {string} = {}\n  return a, ''\nend\nuse(f)",
    "local enum E\n  'a'\n  'b'\nend\nlocal function f(): E?, string\n  local e: E = 'a'\n  return e, ''\nend\nuse(f)",
    "local record R\n  n: integer\nend\nlocal function f(): R?, string\n  local r: R = { n = 1 }\n  return r, ''\nend\nuse(f)",
  })
  keeps({ "local function f(r: {string}?): {string}?, string\n  return r, ''\nend\nuse(f)" })
end

local function test_a_callee_whose_last_parameter_is_no_string_does_not_take_the_reason_and_two_problems_on_a_line_come_in_text_order()
  breaches("its error slot is dropped", { "local function other(_v: integer?, _why: any) end\nother(get())" })
  local found = problems_of("put() use(get())")
  assert(#found == 2 and found[1]:find("get: ", 1, true) ~= nil and found[2]:find("put: ", 1, true) ~= nil, table.concat(found, "\n"))
end
