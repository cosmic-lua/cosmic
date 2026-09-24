--- The error-slot discipline `build.contracts` holds a checked module
--- to: a flagged and an allowed case for each thing it tells apart.
local ast = require("build.ast")
local contracts = require("build.contracts")
local receivers = require("build.receivers")
local Store = require("cosmic.store")
local teal = require("build.teal")

local built = teal.lazy()

--- What the checker gets for a module it asks for: the source, then a
--- close.
local record Served
  text: string
  read: function(Served, what: string): string
  close: function(Served): boolean
end

--- Answers `cosmic.*` from this binary's own sources, so a case can
--- require the real `cosmic.sys`.
local function serve_cosmic(name: string, _search_all: boolean): string | nil, any
  if name:sub(1, 7) ~= "cosmic." then return nil end
  local source, _ = Store.source(name)
  if source == nil then return nil end
  local answer: Served = {
    text = source,
    read = function(self: Served, _what: string): string return self.text end,
    close = function(_self: Served): boolean return true end,
  }
  return name:gsub("%.", "/") .. ".tl", answer
end

--- What `contracts.check` says of `source`, a module the checker takes
--- as it is, with a fallible value `get`, a fallible effect `put`, and
--- two calls that are not fallible in front of it.
local function problems_in(source: string): {string}
  built.path = ""
  built.search_module = serve_cosmic
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
  return contracts.check("x.tl", checked, state, contracts.quiet_records(env))
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
  contracts.exempt["x.tl:f"] = "a test's own exemption"
  local found = problems_in(source)
  contracts.exempt["x.tl:f"] = nil
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
