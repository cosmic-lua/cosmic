--- The error-slot discipline `build.contracts` holds a checked module
--- to: a flagged and an allowed case for each thing it tells apart.
local ast = require("build.ast")
local contracts = require("build.contracts")
local receivers = require("build.receivers")
local teal = require("build.teal")

local built = teal.lazy()

--- What `contracts.check` says of `source`, a module the checker takes
--- as it is, with a fallible value `get`, a fallible effect `put`, and
--- two calls that are not fallible in front of it.
local function problems_in(source: string, exemptions?: contracts.Exemptions): {string}
  -- A case may require the real `cosmic.sys`.
  teal.serve_standard(built)
  local env = assert(built.new_env({
    defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" },
  }))
  -- A stand-in `cosmic.log`, known to the checker the way the importer
  -- makes a compiled module known to the ones after it.
  local log_code, log_result = built.gen(table.concat({
    "local record Log",
    "  record Logger",
    "    say: function(Logger, string): boolean, string",
    "    flush: function(Logger): boolean, string",
    "  end",
    "end",
    "function Log.new(): Log.Logger",
    "  return {",
    "    say = function(_: Log.Logger, _line: string): boolean, string return true, '' end,",
    "    flush = function(_: Log.Logger): boolean, string return true, '' end,",
    "  }",
    "end",
    "return Log",
  }, "\n"), env, nil, "tl")
  assert(log_code ~= nil, "the stand-in cosmic.log did not compile")
  env.modules["cosmic.log"] = log_result.type
  local state = receivers.install(env)
  local prelude = table.concat({
    "local function get(): integer | nil, string return nil, 'none' end",
    "local function put(): boolean, string return true, '' end",
    "local function name(): string return 'x' end",
    "local function pair(): boolean, integer return true, 1 end",
    "local function use(...: any) end",
    "local function complain(_v: integer | nil, _why: string) end",
    "local function lead(_a: string, _b: string, _c?: integer) end",
    "local function maybe(_v: integer | nil, _why?: string) end",
    "local function sget(): string | nil, string return nil, 'none' end",
    "local record Log",
    "  note: function(Log, integer | nil, string)",
    "end",
    "local log: Log = { note = function(_: Log, _v: integer | nil, _why: string) end }",
  }, "\n") .. "\n"
  local code, result = built.gen(prelude .. source, env, nil, "tl")
  assert(code ~= nil and #result.type_errors == 0 and #result.syntax_errors == 0,
    result.type_errors[1] ~= nil and result.type_errors[1].msg or "did not compile")
  local checked = result.ast as ast.Node -- cast: tl's checked AST
  return contracts.check("x.tl", checked, state, contracts.quiet_records(env),
    contracts.binding_tables(env), exemptions, result.type)
end

--- Exemptions naming `keys` in the table `which` alone, in place of
--- build.contracts' own.
local function exempting(which: string, keys: {string}): contracts.Exemptions
  local out: contracts.Exemptions = { exempt = {}, parsing = {}, casts = {}, modes = {} }
  local named: {string: string} = which == "exempt" and out.exempt
    or which == "parsing" and out.parsing or which == "modes" and out.modes or out.casts
  for _, key in ipairs(keys) do named[key] = "a test's own exemption" end
  return out
end

local function flags(source: string, wanted: string)
  local found = problems_in(source)
  assert(#found == 1, "expected one problem, got " .. #found .. ":\n" ..
    table.concat(found, "\n") .. "\nin:\n" .. source)
  assert(found[1]:find(wanted, 1, true) ~= nil, found[1])
end

local function allows(source: string)
  local found = problems_in(source)
  assert(#found == 0, table.concat(found, "\n") .. "\nin:\n" .. source)
end

local function test_a_dropped_error_slot_is_flagged_wherever_it_is_truncated()
  local dropped = "its error slot is dropped"
  flags("local v = get() or 0\nuse(v)", dropped)
  flags("use(not put())", dropped)
  flags("if get() then use(1) end", dropped)
  flags("use(get() == 1)", dropped)
  flags("use(get(), 1)", dropped)
  flags("local v = get()\nuse(v)", dropped)
  flags("local v, w = get(), 1\nuse(v, w)", dropped)
  flags("use((get()))", dropped)
end

local function test_an_ignored_effect_is_flagged_as_a_statement()
  flags("put()", "its failure is ignored")
  flags("get()", "its failure is ignored")
end

--- A block's first statement starts where its callee does; the block's
--- own type stored there after it must not hide the callee's.
local function test_a_call_that_opens_a_block_is_still_judged()
  local ignored = "its failure is ignored"
  flags("do put() end", ignored)
  flags("local function f() put() end\nuse(f)", ignored)
  flags("use(function() put() end)", ignored)
  flags("if 1 > 0 then put() end", ignored)
  flags("for _ = 1, 2 do put() end", ignored)
  flags("while 1 < 0 do put() end", ignored)
end

--- A call whose callee is itself a call's answer is judged by the
--- function type that answer has.
local function test_a_chained_call_is_judged_by_the_inner_answer()
  local source = "local function mk(): function(): boolean, string return put end\n"
  flags(source .. "mk()()", "its failure is ignored")
  allows(source .. "local _, _ = mk()()")
  allows("local function named(): function(): string return name end\nnamed()()")
end

local function test_a_table_item_drops_the_error_slot()
  local dropped = "its error slot is dropped"
  flags("use({get()})", dropped)
  flags("use({get(), 1})", dropped)
  flags("use({1, get()})", dropped)
end

--- Only a call that takes the reason keeps it as a last argument.
local function test_a_last_argument_keeps_its_slot_only_where_a_reason_lands()
  local dropped = "its error slot is dropped"
  flags("use(get())", dropped)
  flags("print(get())", dropped)
  flags("use(select(1, get()))", dropped)
  flags("local t: {string} = {}\ntable.insert(t, get())", dropped)
  allows("use(assert(get()))")
  allows("complain(get())")
  -- The reason would land in a parameter that is not the last.
  flags("lead(sget())", dropped)
  -- The reason would land in an optional parameter.
  flags("maybe(get())", dropped)
  -- A binding's errno, in a third result, lands in a third parameter.
  allows("local triple: function(): integer | nil, string, integer\n" ..
    "local function take(_v: integer | nil, _why: string, _errno: integer) end\ntake(triple())")
  allows("log:note(get())")
  allows("log.note(log, get())")
end

local function test_a_kept_error_slot_is_allowed()
  allows("local v, err = get()\nuse(v, err)")
  allows("local v: integer\nlocal err: string\nv, err = get()\nuse(v, err)")
  allows("use(assert(get()))")
  allows("local function f(): integer | nil, string return get() end\nuse(f)")
  allows("local _, _ = put()")
  allows("local ok, _ = put()\nuse(ok)")
end

local function test_a_call_that_cannot_fail_is_not_judged()
  allows("use(name() or 'y')")
  allows("use(not pair())")
  allows("name()")
  allows("pair()")
end

local function test_a_failure_carries_no_value()
  local beside = "beside its reason"
  flags("local function f(): integer | nil, string\n" ..
    "  local v, err = get()\n  if v == nil then return 0, err end\n" ..
    "  return v, ''\nend\nuse(f)", beside)
  flags("local function f(): boolean, string\n" ..
    "  local ok, why = put()\n  return ok, why\nend\nuse(f)", beside)
  flags("local function f(n: integer): integer | nil, string\n" ..
    "  if n > 0 then return n, nil end\n  return nil, 'not positive'\nend\nuse(f)", beside)
  allows("local function f(): integer | nil, string\n" ..
    "  local v, err = get()\n  if v == nil then return nil, err end\n  return v, ''\nend\nuse(f)")
  allows("local function f(): boolean, string\n" ..
    "  local ok, why = put()\n  if not ok then return false, why end\n" ..
    "  return true, ''\nend\nuse(f)")
end

local function test_a_function_nested_in_another_answers_for_its_own_returns()
  allows("local function f(): integer | nil, string\n" ..
    "  local function g(): integer, string return 1, 'two' end\n" ..
    "  use(g)\n  return get()\nend\nuse(f)")
end

local function test_a_reason_is_exactly_a_string()
  local reason = "a failure's reason is exactly a string"
  flags("local function f(): string | nil, integer\n  return nil, 127\nend\nuse(f)", reason)
  flags("local function f(): {string} | nil, integer | string\n  return nil, 'no'\nend\nuse(f)",
    reason)
  flags("local function f(): string | nil, string | nil\n  return nil, 'no'\nend\nuse(f)", reason)
  allows("local function f(): boolean, integer\n  return true, 1\nend\nuse(f)")
  allows("local function f(): integer | nil, integer | nil\n  return nil, nil\nend\nuse(f)")
end

local function test_a_failure_that_cannot_happen_is_not_declared()
  local never = "the declared failure never happens"
  flags("local function f(n: integer): integer | nil, string\n" ..
    "  if n > 0 then return n, '' end\n  return 0, ''\nend\nuse(f)", never)
  allows("local function f(n: integer): integer | nil, string\n" ..
    "  if n > 0 then return n, '' end\n  return nil, 'not positive'\nend\nuse(f)")
  allows("local function f(): integer | nil, string\n" ..
    "  local v, err = get()\n  if v == nil then return nil, err end\n  return v, ''\nend\nuse(f)")
  allows("local function f(): integer | nil, string\n  return get()\nend\nuse(f)")
end

local function test_an_exempt_function_is_not_held_to_the_return_rules()
  local source = "local function f(): integer | nil, string\n  return 1, 'why'\nend\nuse(f)"
  flags(source, "beside its reason")
  local found = problems_in(source, exempting("exempt", { "x.tl:f" }))
  assert(#found == 0, table.concat(found, "\n"))
end

--- A logger's line stands alone as a statement: its failure has nowhere
--- to go. Used any other way, it is held to the rule like any call.
local function test_a_quiet_records_method_may_stand_alone()
  local source = 'local Log = require("cosmic.log")\nlocal logger = Log.new()\n'
  allows(source .. "logger:say('hello')")
  allows(source .. "do logger:say('trouble') end")
  flags(source .. "use(logger:say('hello'))", "its error slot is dropped")
  -- A method the list does not name is held to the rule.
  flags(source .. "logger:flush()", "its failure is ignored")
end

--- Quiet is a record's type, not its name: a record of the program's
--- own called Logger, with the same method, is held to the rule.
local function test_a_record_named_like_a_quiet_one_is_not_quiet()
  flags(table.concat({
    "local record Logger",
    "  say: function(Logger, string): boolean, string",
    "end",
    "local logger: Logger = { say = function(_: Logger, _l: string): boolean, string",
    "  return true, '' end }",
    "logger:say('hello')",
  }, "\n"), "its failure is ignored")
end

--- Rule 5: two slots, and nothing in a third.
local function test_a_fallible_function_declares_exactly_two_results()
  local third = "nothing in a third"
  flags("local function f(): integer | nil, string, integer\n" ..
    "  return nil, 'no', 2\nend\nuse(f)", third)
  flags("local function f(): boolean, string, integer\n" ..
    "  return false, 'no', 2\nend\nuse(f)", third)
  -- A third slot beside a failure is refused whatever it holds.
  flags("local function f(): boolean, string, {string}\n" ..
    "  return true, '', {}\nend\nuse(f)", third)
  flags("local t = {}\nt.f = function(): integer | nil, string, integer\n" ..
    "  return nil, 'no', 2\nend\nuse(t)", third)
  -- A variadic tail is as many slots as a caller binds.
  flags("local function f(): integer | nil, string...\n" ..
    "  return nil, 'no', 'more'\nend\nuse(f)", third)
  -- A record's function and a method are held the same.
  flags("local record R end\nfunction R.f(): integer | nil, string, integer\n" ..
    "  return nil, 'no', 2\nend\nuse(R)", third)
  flags("local record R end\nfunction R:f(): boolean, string, integer\n" ..
    "  use(self)\n  return false, 'no', 2\nend\nuse(R)", third)
  -- `any` admits nil, so it is a value that can fail.
  flags("local function f(): any, string, integer\n" ..
    "  return nil, 'no', 2\nend\nuse(f)", third)
  allows("local function f(): integer | nil, string\n  return get()\nend\nuse(f)")
  -- Three results that are not a failure's are no failure's shape.
  allows("local function f(): integer, integer, string\n" ..
    "  return 1, 2, 'x'\nend\nuse(f)")
end

--- A function stored into a field of `cosmic.sys` stands in for a
--- binding and keeps the binding's `nil, error, errno`.
local function test_a_stand_in_for_a_sys_binding_keeps_its_errno()
  local sys = "local sys = require('cosmic.sys')\n"
  local stat = "local stat = sys.stat\n"
  allows(sys .. stat .. "sys.stat = function(path: string): sys.Stat | nil, string, integer\n" ..
    "  local st, trouble, errno = stat(path)\n  return st, trouble, errno\nend")
  -- A stand-in is still held to the rules its binding keeps: a
  -- failure of its own answers nil beside the reason.
  flags(sys .. "local mkdir = sys.mkdir\n" ..
    "sys.mkdir = function(path: string, mode?: integer): boolean, string, integer\n" ..
    "  if path == '' then return true, 'empty' end\n  return mkdir(path, mode)\nend",
    "beside its reason")
  -- A local named `sys` that is another table is no stand-in's owner.
  flags("local real = require('cosmic.sys')\n" ..
    "local record Other\n  stat: function(string): integer | nil, string, integer\nend\n" ..
    "local sys: Other = {}\n" ..
    "sys.stat = function(_: string): integer | nil, string, integer\n" ..
    "  return nil, 'no', 2\nend\nuse(real)", "nothing in a third")
  -- Only an answer handed on as the names it was bound to keeps its
  -- errno; a value made up beside a reason is still refused.
  flags(sys .. "sys.mkdtemp = function(_: string): string | nil, string, integer\n" ..
    "  return 'v', 'oops', 1\nend", "beside its reason")
  -- The same function stored anywhere else is held to the rules.
  flags(sys .. stat .. "local t = {}\n" ..
    "t.stat = function(path: string): sys.Stat | nil, string, integer\n" ..
    "  local st, trouble, errno = stat(path)\n  return st, trouble, errno\nend\nuse(t)",
    "nothing in a third")
  -- A caller that needs the errno reads it from the binding itself.
  allows(sys .. "local function missing(path: string): boolean | nil, string\n" ..
    "  local st, trouble, errno = sys.stat(path)\n" ..
    "  if st ~= nil then return false, '' end\n" ..
    "  if errno == sys.ENOENT then return true, '' end\n" ..
    "  return nil, trouble\nend\nuse(missing)")
end

--- Rule 6: a reason is read for what it says in none of these ways.
local function test_a_reason_read_for_what_it_says_is_flagged()
  local read = "a failure's reason is read for what it says"
  local bound = "local v, err = get()\n"
  flags(bound .. "use(v, err:find('none'))", read)
  flags(bound .. "use(v, err:match('^n'))", read)
  flags(bound .. "for w in err:gmatch('%a') do use(v, w) end", read)
  flags(bound .. "use(v, err:sub(1, 4))", read)
  flags(bound .. "use(v, err:byte(1))", read)
  flags(bound .. "use(v, string.find(err, 'none'))", read)
  flags(bound .. "use(v, string.match(err, 'n'))", read)
  flags(bound .. "use(v, err == 'none')", read)
  flags(bound .. "use(v, 'none' ~= err)", read)
  -- An effect's reason, and one bound by an assignment.
  flags("local ok, why = put()\nuse(ok, why == 'full')", read)
  flags("local v: integer\nlocal err: string\nv, err = get()\nuse(v, err:find('x'))", read)
  -- Through the rest of the block, nested blocks and functions too.
  flags(bound .. "if v == nil then use(err:find('none')) end", read)
  flags(bound .. "use(v, function(): boolean return err == 'none' end)", read)
end

local function test_a_reason_passed_on_or_compared_with_empty_is_allowed()
  local bound = "local v, err = get()\n"
  allows(bound .. "use(v, err == '', err ~= '', '' == err)")
  allows(bound .. "if err then use(v) end")
  allows(bound .. "use(v, 'get: ' .. err, string.format('%s', err), #err > 0)")
  allows(bound .. "complain(v, err)")
  allows(bound .. "use(v, err:gsub('\\n', ' '))")
  allows("local function f(): integer | nil, string\n" ..
    "  local v, err = get()\n  if v == nil then return nil, 'f: ' .. err end\n" ..
    "  return v, ''\nend\nuse(f)")
end

--- Only a reason's name is followed, and only while that binding holds.
local function test_a_name_that_holds_no_reason_is_not_followed()
  local read = "a failure's reason is read for what it says"
  -- A string from a call that cannot fail, or a second result that is
  -- not a reason.
  allows("local s = name()\nuse(s:find('x'))")
  allows("local function two(): string, string return 'a', 'b' end\n" ..
    "local a, b = two()\nuse(a, b:find('b'))")
  -- Another binding of the name takes over.
  allows("local v, err = get()\nerr = name()\nuse(v, err:find('x'))")
  allows("local v, err = get()\nuse(v, function(err: string): boolean\n" ..
    "  return err:find('x') ~= nil\nend)")
  allows("local v, err = get()\nuse(v)\nfor _, err in ipairs({'a'}) do use(err:find('a')) end")
  -- A declaration in an inner block holds only there.
  flags("local v, err = get()\ndo local err = name() use(err:find('x')) end\n" ..
    "use(v, err:find('x'))", read)
  allows("local err = name()\ndo local v, err = get() use(v, err) end\nuse(err:find('x'))")
  -- A reason reached without a name drops its slot: rule 1 says so.
  flags("use(select(2, get()) == 'none')", "its error slot is dropped")
end

--- A reason assigned in an inner block is still the name's after the
--- block closes, and so is one bound before it that the block may not
--- have replaced; a store into a local of the closed block is not.
local function test_a_reason_assigned_in_an_inner_block_is_followed_past_it()
  local read = "a failure's reason is read for what it says"
  flags("local v, err = get()\nif v == nil then\n  v, err = get()\nend\nuse(v, err:find('x'))", read)
  flags("local v: integer\nlocal err = ''\nif name() == 'a' then\n  v, err = get()\nend\n" ..
    "use(v, err:match('x'))", read)
  flags("local v, err = get()\nif v == nil then\n  err = name()\nend\nuse(v, err:find('x'))", read)
  allows("local err = name()\ndo\n  local v, err2 = get()\n  do\n    local err: string\n" ..
    "    v, err = get()\n    use(err2)\n  end\n  use(v)\nend\nuse(err:find('x'))")
  allows("local err = name()\nif name() == 'a' then\n  err = name()\nend\nuse(err:find('x'))")
end

--- A comparison reads a reason whatever it compares it with but `""`
--- or `nil`: a named constant, a call, an ordering.
local function test_a_reason_compared_with_anything_but_empty_is_flagged()
  local read = "a failure's reason is read for what it says"
  local bound = "local TIMEOUT <const> = 'timeout'\nlocal v, err = get()\n"
  flags(bound .. "use(v, err == TIMEOUT)", read)
  flags(bound .. "use(v, name() ~= err)", read)
  flags(bound .. "use(v, err < 'm')", read)
  flags(bound .. "use(v, err >= TIMEOUT)", read)
  allows(bound .. "use(v, TIMEOUT, err == nil, nil ~= err, err ~= '')")
end

--- What only wraps a name reads the name.
local function test_a_reason_read_through_a_wrapper_is_flagged()
  local read = "a failure's reason is read for what it says"
  local bound = "local v, err = get()\n"
  flags(bound .. "use(v, (err):find('x'))", read)
  flags(bound .. "use(v, tostring(err):find('x'))", read)
  flags(bound .. "use(v, err:lower():find('x'))", read)
  flags(bound .. "use(v, string.find(err:upper(), 'X'))", read)
  flags(bound .. "use(v, tostring(err) == 'x')", read)
  allows(bound .. "use(v, tostring(err) .. '!', err:lower())")
end

--- A name bound to a reason alone holds the reason.
local function test_a_name_bound_to_a_reason_holds_it()
  local read = "a failure's reason is read for what it says"
  local bound = "local v, err = get()\n"
  flags(bound .. "local why = err\nuse(v, why:find('x'))", read)
  flags(bound .. "local why = err\nlocal again = why\nuse(v, again == 'x')", read)
  flags(bound .. "local a, why = v, err\nuse(a, why:find('x'))", read)
  flags(bound .. "local why: string\nwhy = tostring(err)\nuse(v, why:sub(1, 2))", read)
  allows(bound .. "local why = 'get: ' .. err\nuse(v, why:find('x'))")
  allows(bound .. "local why = err\nwhy = name()\nuse(v, why:find('x'))")
end

--- A `local`'s own right-hand side reads the binding before it.
local function test_a_local_reads_its_own_name_from_before_it()
  local read = "a failure's reason is read for what it says"
  flags("local v, err = get()\nlocal err2 = err:find('x')\nuse(v, err2)", read)
  flags("local v, err = get()\ndo local err = err:sub(1, 2) use(err) end\nuse(v)", read)
  flags("local v, err = get()\ndo local err = err use(err:find('x')) end\nuse(v)", read)
  allows("local err = name()\ndo local v, err = get() use(v, err) end\n" ..
    "local e = err:find('x')\nuse(e)")
end

--- A function the `parsing` table names is not held to rule 6.
local function test_a_parsing_exempt_function_is_not_held_to_rule_6()
  local source = "local function f()\n  local v, err = get()\n  use(v, err:find('x'))\nend\nuse(f)"
  flags(source, "a failure's reason is read for what it says")
  local found = problems_in(source, exempting("parsing", { "x.tl:f" }))
  assert(#found == 0, table.concat(found, "\n"))
end

local cast = "a cast tells the checker what it could not prove"

--- Rule 7: a cast is flagged wherever it stands, named by the function
--- it stands in, or as the top level.
local function test_a_cast_is_flagged()
  flags("local function f(v: any): integer return v as integer end\nuse(f)", "f: " .. cast)
  flags("local t: {any} = {}\nuse(t[1] as string)", "the top level: " .. cast)
  flags("local f = function(v: any): integer return v as integer end\nuse(f)", "f: " .. cast)
  flags("local r: {string: function(any): integer} = {}\n" ..
    "r.g = function(v: any): integer return v as integer end", "r.g: " .. cast)
end

--- A narrowing is no cast.
local function test_a_narrowing_is_not_a_cast()
  allows("local t: {any} = {}\nlocal v = t[1]\nif v is string then use(v) end")
end

--- A function the `casts` table names may cast; one it does not may not,
--- even beside it.
local function test_a_cast_exempt_function_may_cast()
  local source = "local function f(v: any): integer return v as integer end\n" ..
    "local g = function(v: any): string return v as string end\nuse(f, g)"
  local one = problems_in(source, exempting("casts", { "x.tl:f" }))
  local none = problems_in(source, exempting("casts", { "x.tl:f", "x.tl:g" }))
  assert(#one == 1 and one[1]:find("g: " .. cast, 1, true) ~= nil, table.concat(one, "\n"))
  assert(#none == 0, table.concat(none, "\n"))
end

--- The raw module the core hands a chunk may be cast at the top level,
--- and only there; no other top-level cast may.
local function test_the_handed_raw_module_may_be_cast_at_the_top_level()
  local handed = "local extra: any = select(2, ...)\n"
  allows(handed .. "use(extra as {string})")
  allows(handed .. "if extra is {string} then use(1) else use((extra) as {string}) end")
  flags(handed .. "local function f(): {string} return extra as {string} end\nuse(f)",
    "f: " .. cast)
  flags("local other: any = select(1, ...)\nuse(other as {string})", "the top level: " .. cast)
  flags("use({} as {string})", "the top level: " .. cast)
end

--- An exemption key names a record's function as it is written, a
--- nested function under the one around it, and a top-level table's
--- function field under the table.
local function test_an_exemption_key_names_the_function_as_written()
  flags("local record R end\nfunction R.m(v: any): integer return v as integer end",
    "R.m: " .. cast)
  flags("local record R end\nfunction R:m(v: any): integer return v as integer end",
    "R:m: " .. cast)
  flags("local t = { g = function(v: any): integer return v as integer end }\nuse(t)",
    "t.g: " .. cast)
  local nested = "local function f()\n" ..
    "  local function g(v: any): integer return v as integer end\n  use(g)\nend\nuse(f)"
  flags(nested, "f.g: " .. cast)
  -- A top-level function of the same name excuses nothing nested.
  local inherited = problems_in(nested, exempting("casts", { "x.tl:g" }))
  local joined = table.concat(inherited, "\n")
  assert(#inherited == 2 and joined:find("f.g: " .. cast, 1, true) ~= nil
    and joined:find("contracts.casts names x.tl:g,", 1, true) ~= nil, joined)
  local exempt = problems_in(nested, exempting("casts", { "x.tl:f.g" }))
  assert(#exempt == 0, table.concat(exempt, "\n"))
end

--- Rule 6 keys a nested function the same way.
local function test_a_parsing_exemption_names_a_nested_function()
  local source = "local function f()\n  local function g()\n" ..
    "    local v, err = get()\n    use(v, err:find('x'))\n  end\n  use(g)\nend\nuse(f)"
  local found = problems_in(source, exempting("parsing", { "x.tl:f.g" }))
  assert(#found == 0, table.concat(found, "\n"))
end

--- An exemption its file's check finds no use for is refused.
local function test_a_stale_exemption_is_refused()
  local unused = "which no longer needs it"
  local casts = problems_in("use(1)", exempting("casts", { "x.tl:gone" }))
  assert(#casts == 1 and casts[1]:find("contracts.casts names x.tl:gone, " .. unused, 1, true),
    table.concat(casts, "\n"))
  local parsing = problems_in("local function f() local v, err = get() use(v, err) end\nuse(f)", exempting("parsing", { "x.tl:f" }))
  assert(#parsing == 1 and parsing[1]:find("contracts.parsing names x.tl:f, " .. unused, 1, true),
    table.concat(parsing, "\n"))
  local exempt = problems_in("use(1)", exempting("exempt", { "x.tl:gone" }))
  assert(#exempt == 1 and exempt[1]:find("contracts.exempt names x.tl:gone, " .. unused, 1, true),
    table.concat(exempt, "\n"))
end

--- A test's tree stubs build/importer.tl to be taken for cosmic's own,
--- and the stub uses no exemption: an entry naming one of its functions
--- is refused whatever module is checked (see `stale`).
local function test_no_exemption_may_name_a_function_of_the_importer()
  for _, which in ipairs({ "exempt", "parsing", "casts", "modes" }) do
    local found = problems_in("use(1)", exempting(which, { "build/importer.tl:generate" }))
    assert(#found == 1 and found[1]:find("names build/importer.tl:generate", 1, true),
      which .. ": " .. table.concat(found, "\n"))
  end
end

--- Rules 2 to 5 key an exemption as the other tables do: a nested
--- function under the one around it.
local function test_an_exempt_function_is_keyed_by_its_scope()
  local source = "local function f()\n" ..
    "  local function g(): integer | nil, string return 1, 'x' end\n  use(g)\nend\nuse(f)"
  flags(source, "a failure answers nil beside its reason")
  local found = problems_in(source, exempting("exempt", { "x.tl:f.g" }))
  assert(#found == 0, table.concat(found, "\n"))
end

local stutters = "a type repeats its module's name"

--- Rule 8: a type the returned record declares is refused when its name
--- is the module's, or starts with it and then a capital.
local function test_a_type_repeating_its_module_is_flagged()
  flags("local record Zip\n  record ZipReader\n    n: integer\n  end\nend\nreturn Zip",
    "Zip.ZipReader: " .. stutters .. ", which every use already says; call it Zip.Reader")
  flags("local record Zip\n  enum Zip\n    \"a\"\n  end\nend\nreturn Zip",
    "Zip.Zip: " .. stutters)
  flags("local record zip\n  type ZipKind = string\nend\nreturn zip",
    "zip.ZipKind: " .. stutters)
end

--- A name that only starts with the module's letters (`Logger` in
--- `Log`), a plain field, and a type of a record the chunk does not
--- return are allowed.
local function test_a_type_of_its_own_name_is_allowed()
  allows("local record Log\n  record Logger\n    n: integer\n  end\n" ..
    "  record Reader\n    n: integer\n  end\n  LogLevel: integer\nend\nreturn Log")
  allows("local record Zip\n  record ZipReader\n    n: integer\n  end\nend\n" ..
    "local record Other\nend\nuse(Zip)\nreturn Other")
end

local modal = "is a closed set of modes"

--- Rule 9: an option record's string field compared with two literals is
--- flagged, followed through a local, a default after `or`, and a local
--- function's parameter.
local function test_a_string_mode_is_flagged()
  local record_source = "local record Options\n  links: string\nend\n"
  flags(record_source .. "local function f(o: Options)\n" ..
    "  if o.links == 'skip' then use(1) elseif o.links ~= 'create' then use(2) end\nend\nuse(f)",
    "Options.links: a string compared with \"create\", \"skip\" " .. modal)
  flags(record_source .. "local function f(o: Options)\n" ..
    "  local mode = o.links or 'skip'\n  if mode == 'create' then use(1) end\nend\nuse(f)",
    "Options.links: a string compared with \"create\", \"skip\" " .. modal)
  flags("local record R\n  record WriterOptions\n    method: string\n  end\nend\n" ..
    "local function g(name: string)\n  if name == 'store' then use(1) elseif name == 'deflate' then use(2) end\nend\n" ..
    "local function f(o: R.WriterOptions)\n  g(o.method)\nend\nuse(f)",
    "R.WriterOptions.method: a string compared with \"deflate\", \"store\" " .. modal)
end

--- One literal, `""`, an enum, an open string never compared, a record
--- that is not an option record, and a field of the same name on
--- another record are allowed.
local function test_a_string_that_is_no_mode_is_allowed()
  allows("local record Options\n  links: string\nend\n" ..
    "local function f(o: Options)\n  if o.links == 'create' or o.links == '' then use(1) end\nend\nuse(f)")
  allows("local enum Links\n  'skip'\n  'create'\nend\nlocal record Options\n  links: Links\nend\n" ..
    "local function f(o: Options)\n  if o.links == 'skip' or o.links == 'create' then use(1) end\nend\nuse(f)")
  allows("local record Options\n  path: string\nend\n" ..
    "local function f(o: Options)\n  use(o.path .. '/x')\nend\nuse(f)")
  allows("local record Entry\n  kind: string\nend\n" ..
    "local function f(e: Entry)\n  if e.kind == 'a' or e.kind == 'b' then use(1) end\nend\nuse(f)")
  allows("local record Options\n  kind: string\nend\nlocal record Other\n  kind: string\nend\n" ..
    "local function f(o: Options, e: Other)\n" ..
    "  if e.kind == 'a' or e.kind == 'b' then use(o.kind) end\nend\nuse(f)")
end

--- A field `modes` names may be compared with literals; an entry no
--- field needs is stale.
local function test_a_modes_exemption_excuses_and_goes_stale()
  local source = "local record Options\n  links: string\nend\n" ..
    "local function f(o: Options)\n  if o.links == 'skip' or o.links == 'create' then use(1) end\nend\nuse(f)"
  local found = problems_in(source, exempting("modes", { "x.tl:Options.links" }))
  assert(#found == 0, table.concat(found, "\n"))
  local stale = problems_in("use(1)", exempting("modes", { "x.tl:Options.gone" }))
  assert(#stale == 1 and stale[1]:find("contracts.modes names x.tl:Options.gone, which no longer needs it",
    1, true) ~= nil, table.concat(stale, "\n"))
end

--- Rule 8 reads nested types, the module's name in any case, and a
--- module that returns a `local` declared as its record.
local function test_a_nested_or_recased_repeat_is_flagged()
  flags("local record Zip\n  record Entry\n    enum ZipKind\n      'a'\n    end\n  end\nend\nreturn Zip",
    "Zip.Entry.ZipKind: " .. stutters .. ", which every use already says; call it Zip.Entry.Kind")
  flags("local record Sqlite\n  record SQLiteHandle\n    n: integer\n  end\nend\nreturn Sqlite",
    "Sqlite.SQLiteHandle: " .. stutters)
  flags("local record Layout\n  record LayoutRule\n    n: integer\n  end\nend\n" ..
    "local layout: Layout = {}\nreturn layout", "layout.LayoutRule: " .. stutters)
end

--- Rule 9 reads a `string | nil` field and a value assigned to a local.
local function test_an_optional_or_assigned_mode_is_flagged()
  flags("local record Options\n  links: string | nil\nend\n" ..
    "local function f(o: Options)\n  if o.links == 'skip' or o.links == 'create' then use(1) end\nend\nuse(f)",
    "Options.links: a string compared with \"create\", \"skip\" " .. modal)
  flags("local record Options\n  links: string\nend\n" ..
    "local function f(o: Options)\n  local m: string\n  m = o.links\n" ..
    "  if m == 'skip' or m == 'create' then use(1) end\nend\nuse(f)",
    "Options.links: a string compared with \"create\", \"skip\" " .. modal)
end

--- A name holds a field only in the function that bound it: another
--- function's local of the same name, or the name bound again, does
--- not.
local function test_a_same_named_local_elsewhere_is_not_the_field()
  allows("local record Options\n  links: string\nend\n" ..
    "local function f(o: Options)\n  local m = o.links\n  if m == 'skip' then use(1) end\nend\n" ..
    "local function g(m: string)\n  if m == 'a' or m == 'b' then use(2) end\nend\nuse(f, g)")
  allows("local record Options\n  links: string\nend\n" ..
    "local function f(o: Options)\n  local m = o.links\n  if m == 'skip' then use(1) end\n" ..
    "  local m2 = m\n  local m = 'x'\n  if m == 'a' or m == 'b' then use(m2) end\nend\nuse(f)")
end

--- Rule 10: what a module exports answers one result, or a failure pair.
local function test_an_exported_tuple_is_flagged()
  local tuple = "an exported function answers one result"
  flags("local record M end\nfunction M.split(): string, string\n" ..
    "  return 'a', 'b'\nend\nreturn M", "M.split: " .. tuple)
  -- Two answers beside each other are a tuple, not a failure.
  flags("local record M end\nfunction M.pair(): boolean, integer\n" ..
    "  return true, 1\nend\nreturn M", tuple)
  -- A variadic answer is as many results as a caller binds.
  flags("local record M end\nfunction M.all(): string...\n" ..
    "  return 'a', 'b'\nend\nreturn M", tuple)
  -- A record declared inside the export exports its methods.
  flags("local record M\n  record R\n    n: integer\n  end\nend\n" ..
    "function M.R:pair(): integer, integer\n  return self.n, self.n\nend\nreturn M",
    "M.R:pair: " .. tuple)
  -- A field the record declares is exported however it is filled.
  flags("local record M\n  f: function(): string, string\nend\n" ..
    "local function f(): string, string return 'a', 'b' end\nM.f = f\nreturn M",
    "M.f: " .. tuple)
  -- A generic function is held the same as any other.
  flags("local record M end\nfunction M.twice<T>(x: T): T, T\n" ..
    "  return x, x\nend\nreturn M", "M.twice: " .. tuple)
  -- A module that answers a constructor exports its fields by name.
  flags("local function split(): string, string return 'a', 'b' end\n" ..
    "return { split = split }", "split: " .. tuple)
end

local function test_an_exported_single_result_or_failure_pair_is_allowed()
  allows("local record M end\nfunction M.one(): string\n  return 'a'\nend\n" ..
    "function M.read(): string | nil, string\n  return sget()\nend\n" ..
    "function M.write(): boolean, string\n  return put()\nend\nreturn M")
  -- A local function keeps whatever shape it likes; only an export is held.
  allows("local record M end\nlocal function split(): string, string\n" ..
    "  return 'a', 'b'\nend\nfunction M.first(): string\n" ..
    "  local a, _ = split()\n  return a\nend\nreturn M")
  -- A record another module declares, only named here, is not this
  -- module's to answer for.
  allows("local record M\n  type Logger = Log\nend\nreturn M")
end

local function test_an_exempt_export_may_answer_a_tuple()
  local found = problems_in("local record M end\nfunction M.split(): string, string\n" ..
    "  return 'a', 'b'\nend\nreturn M", exempting("exempt", { "x.tl:M.split" }))
  assert(#found == 0, table.concat(found, "\n"))
end

--- Rule 11: an exported wrapper over a fallible `cosmic.sys` binding
--- answers the binding's failure.
local function test_an_exported_bare_boolean_over_a_binding_is_flagged()
  local sys = "local sys = require('cosmic.sys')\nlocal record M end\n"
  local bare = "calls cosmic.sys.unlink itself and answers a bare boolean"
  flags(sys .. "function M.rm(p: string): boolean\n" ..
    "  local ok, _ = sys.unlink(p)\n  return ok\nend\nreturn M", "M.rm: " .. bare)
  -- A local function stored into the export is held the same.
  flags(sys .. "local function rm(p: string): boolean\n" ..
    "  local ok, _ = sys.unlink(p)\n  return ok\nend\n" ..
    "local record N\n  rm: function(string): boolean\nend\n" ..
    "local n: N = { rm = rm }\nuse(M)\nreturn n", bare)
  -- A function the record declares, then defines, is the one defined.
  flags("local sys = require('cosmic.sys')\n" ..
    "local record M\n  rm: function(string): boolean\nend\n" ..
    "function M.rm(p: string): boolean\n" ..
    "  local ok, _ = sys.unlink(p)\n  return ok\nend\nreturn M", "M.rm: " .. bare)
  -- A literal bound to a local, then stored, is the one stored.
  flags(sys .. "local rm = function(p: string): boolean\n" ..
    "  local ok, _ = sys.unlink(p)\n  return ok\nend\n" ..
    "use(M)\nreturn { rm = rm }", "rm: " .. bare)
end

local function test_a_wrapper_answering_its_failure_is_allowed()
  local sys = "local sys = require('cosmic.sys')\nlocal record M end\n"
  allows(sys .. "function M.rm(p: string): boolean, string\n" ..
    "  local ok, err = sys.unlink(p)\n  if not ok then return false, err end\n" ..
    "  return true, ''\nend\nreturn M")
  -- A binding called from a function nested in it is that function's.
  allows(sys .. "function M.later(p: string): boolean\n" ..
    "  use(function(): boolean\n    local ok, _ = sys.unlink(p)\n    return ok\n  end)\n" ..
    "  return true\nend\nreturn M")
  -- A local wrapper is not the module's answer.
  allows(sys .. "local function rm(p: string): boolean\n" ..
    "  local ok, _ = sys.unlink(p)\n  return ok\nend\nuse(rm)\nreturn M")
end
