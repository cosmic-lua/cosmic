--- Tests of [`lang.load_order`] through [`lang.check`]: a static (`function R.m(...)`) read by code that runs as the module
--- loads is defined above the code that runs. Each program the checker refuses is run as the Lua it would have been, to show
--- the fault the refusal prevents, and is set beside a twin that defines the static first and runs.
local Ast = require("lang.ast")
local LoadOrder = require("lang.load_order")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

local HEAD <const> = "local record R\n  n: integer\nend\n"
local SIZE <const> = "function R.size(self: R): integer\n  return self.n\nend\n"
local READ <const> = "  return R.size({ n = 1 })\nend\n"
local GO <const> = "local function go(): integer\n" .. READ

--- The codes of the errors of `source`, and the message and fix of the first.
local function verdict(source: string): string, string
  local r = Programs.run(source)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  local first = r.errors[1]
  return Programs.codes(r), first ~= nil and first.msg .. "\n" .. first.fix or ""
end

--- What `source` prints and the error it raised, run although the checker refuses it.
local function lua_of(source: string): {string}, string
  local x = Programs.execute(source, false, nil, nil, nil, true)
  assert(x.ran, "did not run:\n" .. x.lua)
  return x.printed, x.fault or ""
end

--- A program that calls what reads the static `R.size` before the statement that defines it (`call` is placed above `SIZE`)
--- and the same program with the statement first. The first is refused as `static_before_definition` and, run, finds
--- nil; the second is taken and prints `1`.
local function pair(name: string, definitions: string, call: string, head?: string)
  local top = head or HEAD
  local refused = top .. definitions .. call .. SIZE
  local codes, said = verdict(refused)
  assert(codes == "static_before_definition", name .. ": " .. codes .. " " .. said .. "\nin\n" .. refused)
  local _, fault = lua_of(refused)
  assert(fault:find("attempt to call a nil value", 1, true) ~= nil, name .. ": the Lua raised `" .. fault .. "`")
  local twin = top .. definitions .. SIZE .. call
  local twin_codes, twin_said = verdict(twin)
  assert(twin_codes == "", name .. " twin: " .. twin_codes .. " " .. twin_said .. "\nin\n" .. twin)
  local printed, twin_fault = lua_of(twin)
  assert(twin_fault == "" and printed[1] == "1", name .. " twin: " .. twin_fault .. " " .. table.concat(printed, "|"))
end

local function test_a_function_called_as_the_module_loads_reads_only_statics_defined_above_the_call()
  pair("a local function", GO, "print(go())\n")
  pair("a local function in a loop", GO, "for _ = 1, 2 do\n  print(go())\nend\n")
  pair("a local function in a branch", GO, "if 1 > 0 then\n  print(go())\nend\n")
  pair("a local function called by another", GO .. "local function through(): integer\n  return go()\nend\n",
    "print(through())\n")
  pair("a function that calls itself", "local function again(n: integer): integer\n  if n > 0 then\n    return again(n - 1)\n  end\n" ..
      READ, "print(again(2))\n")
  pair("two functions that call each other", "local ping: function(integer): integer = function(_n: integer): integer return 0 end\n" ..
      "local function pong(n: integer): integer\n  if n == 0 then\n    return R.size({ n = 1 })\n  end\n  return ping(n - 1)\nend\n" ..
      "ping = function(n: integer): integer\n  return pong(n)\nend\n", "print(ping(2))\n")
  pair("a function reached through a local assigned after it", "local later: function(): integer = function(): integer return 0 end\n" ..
      "local function first(): integer\n  return later()\nend\nlater = function(): integer\n" .. READ, "print(first())\n")
  pair("a local that holds the function", GO .. "local held = go\n", "print(held())\n")
  pair("a local given a function literal", "local go = function(): integer\n" .. READ, "print(go())\n")
  pair("a literal called where it is written", "", "print((function(): integer\n" .. READ .. ")())\n")
end

local function test_a_function_handed_to_code_that_may_call_it_as_the_module_loads_is_called_there()
  local run = "local function run(f: function(): integer): integer\n  return f()\nend\n"
  pair("a function by its name", GO .. run, "print(run(go))\n")
  pair("a literal", run, "print(run(function(): integer\n" .. READ .. "))\n")
  pair("a function that makes the function", "local function make(): function(): integer\n  return function(): integer\n" ..
      "  return R.size({ n = 1 })\n  end\nend\n", "print(make()())\n")
end

local function test_a_function_of_the_declaration_called_as_the_module_loads_reads_only_statics_defined_above_the_call()
  local calls = "function R.twice(): integer\n  return R.size({ n = 1 }) * 2\nend\n"
  local source = HEAD .. calls .. "print(R.twice())\n" .. SIZE
  local codes, said = verdict(source)
  assert(codes == "static_before_definition" and said:find("`R.twice` is called", 1, true) ~= nil, codes .. said)
  local _, fault = lua_of(source)
  assert(fault:find("attempt to call a nil value", 1, true) ~= nil, fault)
  -- a static that is itself defined later: the function that names it is judged when it runs
  local later = HEAD .. "local function go(): integer\n  return R.first()\nend\nfunction R.first(): integer\n  return R.size({ n = 1 })\nend\n"
  assert(verdict(later .. "print(go())\n" .. SIZE) == "static_before_definition")
  assert(verdict(later .. SIZE .. "print(go())\n") == "")
end

local function test_a_method_of_a_class_called_as_the_module_loads_reads_only_statics_defined_above_the_call()
  local class = "local class C\n  n: integer\n  function get(self): integer\n    return C.zero() + self.n\n  end\nend\n" ..
    "local c: C = { n = 1 }\n"
  local zero = "function C.zero(): integer\n  return 0\nend\n"
  local refused = class .. "print(c:get())\n" .. zero
  local codes, said = verdict(refused)
  assert(codes == "static_before_definition" and said:find("`C.get` is called", 1, true) ~= nil, codes .. said)
  local _, fault = lua_of(refused)
  assert(fault:find("attempt to call a nil value", 1, true) ~= nil, fault)
  local twin = class .. zero .. "print(c:get())\n"
  assert(verdict(twin) == "")
  local printed, twin_fault = lua_of(twin)
  assert(twin_fault == "" and printed[1] == "1", twin_fault)
end

local function test_a_function_stored_in_a_static_is_called_where_the_static_is_called()
  local head = "local record R\n  mut encode: function(): integer\nend\n"
  local written = "local function written(): integer\n  return R.one()\nend\nR.encode = written\n"
  local one = "function R.one(): integer\n  return 1\nend\n"
  -- storing the function calls nothing
  assert(verdict(head .. written .. one) == "")
  assert(verdict(head .. written .. one .. "print(R.encode())\n") == "")
  local early = head .. written .. "print(R.encode())\n" .. one
  local codes, said = verdict(early)
  assert(codes == "static_before_definition" and said:find("`R.encode` is called", 1, true) ~= nil, codes .. said)
  local _, fault = lua_of(early)
  assert(fault:find("attempt to call a nil value", 1, true) ~= nil, fault)
end

local function test_a_function_that_runs_after_the_module_has_loaded_reads_any_static()
  local function accepted(name: string, body: string)
    local codes, said = verdict(HEAD .. body .. SIZE)
    assert(codes == "", name .. ": " .. codes .. " " .. said)
  end
  accepted("a function nothing mentions", GO)
  accepted("a function a function mentions that is not called", GO .. "local function later(): integer\n  return go()\nend\n")
  accepted("a local that holds the function, and is not called", GO .. "local held = go\n")
  accepted("a function that calls itself", "local function again(n: integer): integer\n  if n > 0 then\n    return again(n - 1)\n  end\n" ..
      READ)
  accepted("a function called after the statement", GO .. "local x = 1\n")
  -- a function of a record read by name and not called
  accepted("a static read in a function", "function R.later(): integer\n  return R.size({ n = 1 })\nend\n")
  -- a function of another name is no mention of the first
  accepted("another function in a block", GO .. "do\n  local function other(): integer\n    return 2\n  end\n  print(other())\nend\n")
end

local function test_the_error_names_the_function_the_chain_the_read_and_the_fix()
  local source = HEAD .. GO .. "local function through(): integer\n  return go()\nend\nprint(through())\n" .. SIZE
  local r = Programs.run(source)
  assert(#r.errors == 1, Programs.codes(r))
  local e = assert(r.errors[1])
  assert(e.code == "static_before_definition" and e.y == 10, e.code .. " at " .. tostring(e.y))
  assert(e.msg == "`through` is called, or handed to code that may call it, as the module loads, and through `go` it reads " ..
      "the function `R.size` (line 5) before the statement that defines it has run", e.msg)
  assert(e.fix == "move the statement `function R.size(...)` above this use of `through`, or use `through` in a function " ..
      "that runs after the module has loaded", e.fix)
end

local function test_one_use_is_one_error_and_each_use_has_its_own()
  local source = HEAD .. GO .. "print(go())\nprint(go())\n" .. SIZE
  local r = Programs.run(source)
  assert(Programs.codes(r) == "static_before_definition static_before_definition", Programs.codes(r))
  local first, second = assert(r.errors[1]), assert(r.errors[2])
  assert(first.y == 7 and second.y == 8, tostring(first.y) .. " " .. tostring(second.y))
  local loop = HEAD .. GO .. "for _ = 1, 3 do\n  while true do\n    print(go())\n    break\n  end\nend\n" .. SIZE
  assert(Programs.codes(Programs.run(loop)) == "static_before_definition")
end

-- the follower itself ----------------------------------------------------------------------------------------------

--- A declaration and a node, of a program checked.
local function something(): Types.Decl, Ast.Node
  local run = Programs.run(HEAD .. SIZE)
  for _, decl in pairs(run.lowered.decls) do
    return decl, run.chunk
  end
  error("the program declares nothing")
end

--- A state of `waiting` statics to define, that refuses into `said` and for which every static named in `open` is still to
--- be defined, and the declaration and node to use.
local function state_of(waiting: integer, open: {string: boolean}, said: {string}): LoadOrder.State, Types.Decl, Ast.Node
  local decl, node = something()
  return LoadOrder.new(waiting, function(_decl: Types.Decl, name: string): boolean
    return open[name] == true
  end, function(_node: Ast.Node, spelled: string, found: LoadOrder.Found)
    said[#said + 1] = spelled .. " reads " .. found.read.name .. " through " .. table.concat(found.via, ",")
  end), decl, node
end

local function test_a_mention_follows_the_functions_a_function_mentions_however_far_and_stops_in_a_cycle()
  local said: {string} = {}
  local open = { size = true }
  local state, decl, node = state_of(1, open, said)
  -- function 1 mentions 2, which mentions 3 and 1 again; 3 reads `size`
  LoadOrder.use(state, 1, LoadOrder.of_function(2, "`b`"))
  LoadOrder.use(state, 2, LoadOrder.of_function(1, "`a`"))
  LoadOrder.use(state, 2, LoadOrder.of_function(3, "`c`"))
  LoadOrder.read(state, 3, { decl = decl, name = "size", first = 1 })
  LoadOrder.mention(state, 0, node, LoadOrder.of_function(1, "`a`"))
  assert(#said == 1 and said[1] == "`a` reads size through `b`,`c`", table.concat(said, "|"))
  -- once the static is defined the same mention is fine
  open["size"] = nil
  LoadOrder.mention(state, 0, node, LoadOrder.of_function(1, "`a`"))
  assert(#said == 1, table.concat(said, "|"))
end

local function test_a_mention_in_a_function_is_kept_for_the_day_it_runs_and_none_is_judged_when_nothing_waits()
  local said: {string} = {}
  local state, decl, node = state_of(1, { size = true }, said)
  LoadOrder.read(state, 3, { decl = decl, name = "size", first = 1 })
  LoadOrder.mention(state, 2, node, LoadOrder.of_function(3, "`c`"))
  assert(#said == 0, "a mention in a function is no call")
  LoadOrder.mention(state, 0, node, LoadOrder.of_function(2, "`b`"))
  assert(#said == 1, table.concat(said, "|"))
  local none: {string} = {}
  local idle, idle_decl = state_of(0, { size = true }, none)
  LoadOrder.read(idle, 3, { decl = idle_decl, name = "size", first = 1 })
  LoadOrder.mention(idle, 0, node, LoadOrder.of_function(3, "`c`"))
  assert(#none == 0, "nothing waits")
end

local function test_a_local_and_a_static_are_looked_up_when_the_mention_is_followed()
  local said: {string} = {}
  local state, decl, node = state_of(1, { size = true }, said)
  -- function 1 mentions the local 7 and the static `later` of R, neither of which holds a function yet
  LoadOrder.use(state, 1, LoadOrder.of_local(7, "`held`"))
  LoadOrder.use(state, 1, LoadOrder.of_static(decl, "later", "`R.later`"))
  LoadOrder.read(state, 5, { decl = decl, name = "size", first = 1 })
  LoadOrder.read(state, 6, { decl = decl, name = "size", first = 2 })
  LoadOrder.mention(state, 0, node, LoadOrder.of_function(1, "`a`"))
  assert(#said == 0, table.concat(said, "|"))
  LoadOrder.hold(state, 7, 5)
  LoadOrder.hold(state, 7, 5)
  assert(#(state.held[7] or {}) == 1, "a function a local holds is held once")
  LoadOrder.mention(state, 0, node, LoadOrder.of_function(1, "`a`"))
  assert(#said == 1 and said[1] == "`a` reads size through `held`", table.concat(said, "|"))
  said = {}
  local other, other_decl = state_of(1, { size = true }, said)
  LoadOrder.use(other, 1, LoadOrder.of_static(other_decl, "later", "`R.later`"))
  LoadOrder.read(other, 6, { decl = other_decl, name = "size", first = 2 })
  LoadOrder.define(other, other_decl, "later", 6)
  LoadOrder.mention(other, 0, node, LoadOrder.of_function(1, "`a`"))
  assert(#said == 1 and said[1] == "`a` reads size through `R.later`", table.concat(said, "|"))
end

--- A class whose `meta` metamethod reads the static `C.zero`, and a program that makes a value of it and `use`s it.
local function class_with(meta: string, body: string): string
  local method = meta == "__tostring" and "  function __tostring(self): string\n    return tostring(C.zero())\n  end\n" or
    "  function __close(self)\n    print(C.zero())\n  end\n"
  return "local class C\n  n: integer\n" .. method .. "end\n" .. body
end

local ZERO <const> = "function C.zero(): integer\n  return 0\nend\n"

--- The program `body` of the class with `meta`, with the static after the use, and with it before the class value is made.
local function meta_pair(meta: string, name: string, use: function(string): string)
  local value = "local c: C = { n = 1 }\n"
  local refused = class_with(meta, use(value) .. ZERO)
  local codes, said = verdict(refused)
  assert(codes == "static_before_definition" and said:find("`C." .. meta .. "`", 1, true) ~= nil,
    name .. ": " .. codes .. " " .. said)
  local _, fault = lua_of(refused)
  assert(fault:find("attempt to call a nil value", 1, true) ~= nil, name .. ": " .. fault)
  local twin = class_with(meta, ZERO .. use(value))
  assert(verdict(twin) == "", name .. " twin")
  local _, twin_fault = lua_of(twin)
  assert(twin_fault == "", name .. " twin: " .. twin_fault)
end

local function test_a_value_of_a_class_whose_metamethod_reads_a_static_is_made_after_the_static()
  meta_pair("__tostring", "tostring", function(value: string): string
    return value .. "print(tostring(c))\n"
  end)
  meta_pair("__tostring", "print", function(value: string): string return value .. "print(c)\n" end)
  meta_pair("__close", "a close local", function(_value: string): string
    return "do\n  local c <close>: C = { n = 1 }\nend\n"
  end)
  -- a function that makes the value is a mention of both
  meta_pair("__tostring", "a function that makes the value", function(_value: string): string
    return "local function make(): C\n  return { n = 1 }\nend\nlocal c = make()\nprint(tostring(c))\n"
  end)
  -- a value nobody makes at load runs nothing
  local never = class_with("__tostring", "local function make(): C\n  return { n = 1 }\nend\n" .. ZERO)
  assert(verdict(never) == "")
end

local SIZED <const> = "local interface Sized\n  size: function(self: Sized): integer\nend\n" ..
  "local class Bag is Sized\n  n: integer\n  function size(self): integer\n    return Bag.zero() + self.n\n  end\nend\n" ..
  "local bag: Bag = { n = 1 }\n"
local BAG_ZERO <const> = "function Bag.zero(): integer\n  return 0\nend\n"

--- `use` run at load through the interface `Sized`, above the static it reads and below it.
local function through_interface(name: string, use: string)
  local refused = SIZED .. use .. BAG_ZERO
  local codes, said = verdict(refused)
  assert(codes == "static_before_definition", name .. ": " .. codes .. " " .. said)
  local _, fault = lua_of(refused)
  assert(fault:find("attempt to call a nil value", 1, true) ~= nil, name .. ": " .. fault)
  local twin = SIZED .. BAG_ZERO .. use
  assert(verdict(twin) == "", name .. " twin")
  local printed, twin_fault = lua_of(twin)
  assert(twin_fault == "" and printed[1] == "1", name .. " twin: " .. twin_fault)
end

local function test_a_method_called_through_an_interface_is_judged_as_the_method_of_the_classes_that_list_it()
  through_interface("a local typed as the interface", "local s: Sized = bag\nprint(s:size())\n")
  through_interface("a parameter", "local function use(s: Sized): integer\n  return s:size()\nend\nprint(use(bag))\n")
  through_interface("a result", "local function mk(): Sized\n  local b: Bag = { n = 1 }\n  return b\nend\nprint(mk():size())\n")
  -- the interfaces it extends
  local extended = "local interface Base\n  size: function(self: Base): integer\nend\nlocal interface Sized is Base\nend\n" ..
    "local class Bag is Sized\n  n: integer\n  function size(self): integer\n    return Bag.zero() + self.n\n  end\nend\n" ..
    "local bag: Bag = { n = 1 }\nlocal function use(s: Base): integer\n  return s:size()\nend\n"
  assert(verdict(extended .. "print(use(bag))\n" .. BAG_ZERO) == "static_before_definition")
  assert(verdict(extended .. BAG_ZERO .. "print(use(bag))\n") == "")
  -- a method of a class that does not list the interface is no method of it
  local other = SIZED .. "local class Other\n  function size(self): integer\n    return Other.zero()\n  end\nend\n" ..
    "local function use(s: Sized): integer\n  return s:size()\nend\nfunction Other.zero(): integer\n  return 0\nend\n" ..
    BAG_ZERO .. "print(use(bag))\n"
  assert(verdict(other) == "")
end

local function test_a_function_that_may_be_nil_is_mentioned_where_it_is_read()
  local g = GO .. "local g: (function(): integer)? = go\n"
  pair("an optional local", g, "print(assert(g)())\n")
end
