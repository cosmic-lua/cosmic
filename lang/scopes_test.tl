--- Tests of [`lang.scopes`]: a case for each rule of scoping, each error with
--- its code, place and fix, and the facts the checker's rules read (what is
--- assigned, captured, and assigned after a capture). Every case also holds
--- [`lang.scopes_cover`].
local Ast = require("lang.ast")
local Cover = require("lang.scopes_cover")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")

Test.policy{}

--- The globals the cases may use.
local GLOBALS <const>: {string: Scopes.Global} = {
  print = { space = "value", const = true },
  require = { space = "value", const = true },
  string = { space = "both", const = false },
  thread = { space = "type", const = false },
  counter = { space = "value", const = false },
  pairs = { space = "value", const = true },
}

--- A case: the source parsed and its scopes built, with the check that the build is consistent.
local record Case
  parsed: Parser.Parsed
  scoped: Scopes.Scoped
  tokens: Lexer.Tokens
end

local function scope(source: string, dialect?: Ast.Dialect): Case
  local parsed = Parser.parse(Lexer.lex(source, "t.tl"), "t.tl", dialect or "tl")
  local scoped = Scopes.build(parsed.chunk, "t.tl", GLOBALS)
  local ok, why = Cover.check(parsed.chunk, scoped, GLOBALS)
  assert(ok, why .. "\n" .. source)
  return { parsed = parsed, scoped = scoped, tokens = parsed.chunk.tokens }
end

local function at(case: Case, token: integer): string
  local line = assert(case.tokens.y[token], "the token is one of the case")
  return tostring(line) .. ":" .. tostring(Lexer.x(case.tokens, token))
end

--- Each name of the source that is used, in order, as `name y:x -> y:x` of where its variable is
--- declared, or `-> global`.
local function binds(source: string): string
  local case = scope(source)
  local out: mut {string} = {}
  local stack: mut {Ast.Node} = { case.parsed.chunk }
  local names: mut {Ast.Name} = {}
  while #stack > 0 do
    local node = stack[#stack]
    stack[#stack] = nil
    if (node.kind == "Name") then
      names[#names + 1] = node
    end
    local children: mut {Ast.Node} = {}
    Ast.children(node, function(child: Ast.Node)
      children[#children + 1] = child
    end)
    while true do
      local child = table.remove(children)
      if child == nil then
        break
      end
      stack[#stack + 1] = child
    end
  end
  for _, n in ipairs(names) do
    local bound = n.binding
    local v = if bound ~= nil then case.scoped.vars[bound] else nil end
    if n.binding ~= nil or case.scoped.globals[n.text] ~= nil then
      out[#out + 1] = n.text .. " " .. at(case, n.first) .. " -> " .. (v ~= nil and at(case, v.declared) or "global")
    end
  end
  return table.concat(out, "; ")
end

--- The errors of the source as `code y:x`.
local function errors(source: string): string
  local out: mut {string} = {}
  for _, e in ipairs(scope(source).scoped.errors) do
    out[#out + 1] = e.code .. " " .. tostring(e.y) .. ":" .. tostring(e.x)
  end
  return table.concat(out, "; ")
end

--- Where the second place of `e` is, as `y:x`, or `none`.
local function place(e: Scopes.Error): string
  local other = e.other
  return if other ~= nil then tostring(other.y) .. ":" .. tostring(other.x) else "none" end
end

--- The one error of the source.
local function one_error(source: string): Scopes.Error
  local list = scope(source).scoped.errors
  local only = list[1]
  assert(#list == 1 and only ~= nil, "expected one error, got " .. tostring(#list) .. ": " .. errors(source))
  return only
end

--- The variable of the source declared as `name`, the `nth` of that name.
local function var(case: Case, name: string, nth?: integer): Scopes.Var
  local seen = 0
  for _, v in ipairs(case.scoped.list) do
    if v.name == name then
      seen = seen + 1
      if seen == (nth or 1) then
        return v
      end
    end
  end
  error("no variable " .. name .. " " .. tostring(nth or 1))
end

--- The `nth` capture of the variable `name` of `case`.
local function capture(case: Case, name: string, nth: integer): Scopes.Capture
  local found = var(case, name).captures[nth]
  assert(found ~= nil, "the variable " .. name .. " has a capture " .. tostring(nth))
  return found
end

local function test_a_local_is_visible_after_its_statement_and_its_value_sees_the_outer_name()
  assert(binds("local x = 1\nlocal x = x\nprint(x)") == "x 2:11 -> 1:7; print 3:1 -> global; x 3:7 -> 2:7")
  assert(binds("local a, b = 1, a\nprint(a, b)") == "a 1:17 -> global; print 2:1 -> global; a 2:7 -> 1:7; b 2:10 -> 1:10")
end

local function test_a_local_function_sees_its_own_name_and_a_local_does_not()
  assert(binds("local function f() return f end") == "f 1:27 -> 1:16")
  assert(binds("local f = function() return f end") == "f 1:29 -> global")
end

local function test_parameters_and_upvalues_resolve_to_the_nearest_binding()
  local source = "local a = 1\nlocal function f(a, b)\n  return function() return a + b end\nend\nprint(a)"
  assert(binds(source) == "a 3:28 -> 2:18; b 3:32 -> 2:21; print 5:1 -> global; a 5:7 -> 1:7")
end

local function test_a_name_is_visible_only_to_the_end_of_its_block()
  local source = "do local x = 1 end\nif counter then local y = 1 else local z = 1 end\nprint(x, y, z)"
  assert(binds(source) == "counter 2:4 -> global; print 3:1 -> global; x 3:7 -> global; y 3:10 -> global; z 3:13 -> global")
  assert(errors(source) == "unknown_variable 3:7; unknown_variable 3:10; unknown_variable 3:13")
end

local function test_the_bounds_of_a_for_loop_are_outside_and_its_variables_inside_the_body()
  assert(binds("local i = 3\nfor i = i, i + 1 do print(i) end\nprint(i)") ==
      "i 2:9 -> 1:7; i 2:12 -> 1:7; print 2:21 -> global; i 2:27 -> 2:5; print 3:1 -> global; i 3:7 -> 1:7")
  assert(binds("local t = {}\nfor k, v in pairs(t) do print(k, v) end\nprint(k)") ==
      "pairs 2:13 -> global; t 2:19 -> 1:7; print 2:25 -> global; k 2:31 -> 2:5; v 2:34 -> 2:8; print 3:1 -> global; k 3:7 -> global")
end

local function test_the_until_of_a_repeat_sees_the_locals_of_its_body()
  assert(binds("repeat local done = counter until done\nprint(done)") ==
      "counter 1:21 -> global; done 1:35 -> 1:14; print 2:1 -> global; done 2:7 -> global")
end

local function test_a_while_condition_is_outside_its_body_and_an_elseif_outside_the_arm_before()
  assert(binds("local n = 1\nwhile n do local n = 2 print(n) end") == "n 2:7 -> 1:7; print 2:24 -> global; n 2:30 -> 2:18")
  assert(binds("if counter then local t = 1 elseif t then print(t) end") ==
      "counter 1:4 -> global; t 1:36 -> global; print 1:43 -> global; t 1:49 -> global")
end

local function test_const_and_close_are_recorded_and_not_assignable()
  local case = scope("local a <const> = 1\nlocal b <close> = counter\nlocal c = 2\nprint(a, b, c)")
  assert(var(case, "a").attr == "const" and var(case, "a").readonly)
  assert(var(case, "b").attr == "close" and var(case, "b").readonly)
  assert(var(case, "c").attr == nil and not var(case, "c").readonly)
  local e = one_error("local a <const> = 1\na = 2")
  assert(e.code == "const_assigned" and e.y == 2 and e.x == 1, e.code)
  assert(e.msg == "`a` is declared `<const>` and cannot be assigned")
  assert(e.fix == "declare it without `<const>` (`local a = ...`) if it changes, or assign a new local")
  assert(place(e) == "1:7")
  local closer = one_error("local a <close> = counter\na = nil")
  assert(closer.code == "const_assigned" and closer.msg == "`a` is declared `<close>` and cannot be assigned")
  assert(closer.fix == "keep the changing value in another local; a `<close>` variable holds one value until its scope ends")
end

local function test_a_loop_control_variable_is_read_only()
  local e = one_error("for i = 1, 3 do i = 2 end")
  assert(e.code == "const_assigned" and e.y == 1 and e.x == 17)
  assert(e.msg == "the control variable `i` of a `for` is read-only in Lua 5.5")
  assert(e.fix == "copy it to a local and change that: `local i_copy = i` in the loop body")
  assert(errors("for k, v in pairs({}) do k = 1 end") == "const_assigned 1:26")
  assert(errors("for k, v in pairs({}) do v = 1 end") == "")
end

local function test_a_class_method_sees_self_the_class_name_and_the_type_parameters()
  local source = "local class Box<T>\n  mut item: T\n  function put(self, x: T): Box<T>\n    self.item = x\n    return self\n  end\nend"
  local case = scope(source)
  assert(case.scoped.errors[1] == nil)
  assert(var(case, "self").kind == "param" and #var(case, "self").reads == 2)
  assert(#var(case, "Box").type_uses == 1 and #var(case, "T").type_uses == 3)
  assert(var(case, "T").kind == "typeparam" and var(case, "T").space == "type")
end

local function test_a_type_declaration_sees_its_own_name_and_a_later_nested_type()
  local source = "local record Node\n  next: Node\n  edge: Edge\n  record Edge\n    to: Node\n  end\nend"
  local case = scope(source)
  assert(case.scoped.errors[1] == nil)
  assert(#var(case, "Node").type_uses == 2 and #var(case, "Edge").type_uses == 1)
end

--- The rule is the new checker's own (the fork resolves a name where the type is used, and accepts
--- `local x: {Later}` too); the tree needs it, writing about 50 such names in signatures and records.
local function test_types_in_a_signature_may_be_declared_later_but_a_local_annotation_may_not()
  assert(errors("local function g<T is Later>(x: T): T return x end\nlocal record Later\n  n: integer\nend") == "")
  assert(errors("local function g<T is Missing>(x: T): T return x end") == "unknown_type 1:23")
  assert(errors("local function f(x: Later): Later end\nlocal record Later\n  n: integer\nend") == "")
  assert(errors("local x: Later = nil\nlocal record Later\n  n: integer\nend") == "unknown_type 1:10")
  assert(errors("local record A\n  b: B\nend\nlocal B = 1") == "not_a_type 2:6")
end

local function test_a_value_is_not_a_type_and_a_type_is_not_a_value()
  local value = one_error("local enum Color \"red\" end\nprint(Color)")
  assert(value.code == "not_a_value" and value.y == 2 and value.x == 7)
  assert(value.msg == "`Color` is an enum, a type, and has no value")
  assert(value.fix == "write `Color` where a type goes (`x: Color`) and a variable or a literal where a value goes")
  assert(place(value) == "1:12")
  local kind = one_error("local function f(n: integer)\n  local x: n = nil\nend")
  assert(kind.code == "not_a_type" and kind.y == 2 and kind.x == 12)
  assert(kind.msg == "`n` is a parameter, a value, and names no type")
  assert(kind.fix == "write a type here: declare it with `local record n ... end`, `local type n = ...` or " ..
      "import it with `local type n = require(\"...\")`")
  assert(errors("local record R end\nprint(R)") == "")
  assert(errors("local m = require(\"m\")\nlocal x: m.T = nil") == "")
end

local function test_a_primitive_type_name_is_never_a_binding()
  assert(errors("local function integer() end\nlocal x: integer = 1\nprint(x)") == "")
  assert(scope("local function integer() end\nlocal x: integer = 1").scoped.resolved[1] == nil)
end

local function test_type_parameters_are_visible_in_their_declaration_and_nowhere_else()
  local source = "local function id<T>(x: T): T\n  local y: T = x\n  return y\nend\nlocal z: T = nil"
  assert(errors(source) == "unknown_type 5:10")
  assert(errors("type Key<K> = {K: K}") == "")
  assert(errors("local record Cache<K>\n  get: function(K): K\nend\nlocal bad: K = nil") == "unknown_type 4:12")
end

local function test_an_import_names_a_module_and_a_type()
  local case = scope("local type fs = require(\"cosmic.fs\")\nlocal x: fs.Error = nil\nprint(fs)")
  assert(var(case, "fs").kind == "import" and var(case, "fs").module == "cosmic.fs" and var(case, "fs").space == "both")
  assert(var(case, "fs").module == "cosmic.fs" and #var(case, "fs").type_uses == 1)
  local alias = scope("local fs = require(\"cosmic.fs\")\nprint(fs)")
  assert(var(alias, "fs").module == "cosmic.fs" and var(alias, "fs").kind == "local")
  local shadowed = scope("local require = print\nlocal fs = require(\"x\")")
  assert(var(shadowed, "fs").module == "")
end

local function test_a_match_binding_is_visible_in_its_arm()
  local source = "local function f(): (true, string) | (false, string) return true, \"\" end\n" ..
    "match f() do\n  | (true, body) then print(body)\n  | (false, why) then print(why, body)\nend"
  assert(binds(source) ==
      "f 2:7 -> 1:16; print 3:23 -> global; body 3:29 -> 3:12; print 4:23 -> global; why 4:29 -> 4:13; body 4:34 -> global")
  assert(var(scope(source), "body").kind == "pattern")
end

local function test_a_narrowing_return_names_a_parameter_of_its_function()
  local source = "local function is_text(v: any): v is string return true end"
  local case = scope(source)
  assert(case.scoped.errors[1] == nil)
  local narrows: Ast.Narrows? = nil
  local stat = case.parsed.chunk.body.stats[1]
  if stat ~= nil and stat.kind == "LocalFunction" then
    local rets = stat.fn.rets
    local first = assert(assert(assert(rets).lists[1])[1])
    if (first.kind == "Narrows") then
      narrows = first
    end
  end
  assert(narrows ~= nil and case.scoped.resolved[narrows.id] == var(case, "v").id)
  local e = one_error("local function f(v: any): w is string return true end")
  assert(e.code == "unknown_parameter" and e.y == 1 and e.x == 27)
  assert(e.msg == "the narrowing return names `w`, which is no parameter of this function")
  assert(e.fix == "write the name of a parameter before `is`: `v is T` for a parameter `v`")
  assert(errors("local type Guard = function(v: any): v is string") == "")
  assert(errors("local type Guard = function(v: any): w is string") == "unknown_parameter 1:38")
end

local function test_a_global_is_recorded_where_it_is_declared_and_refused_where_it_is_not()
  local case = scope("print(string.upper(\"a\"))\nlocal x: thread = nil")
  assert(case.scoped.errors[1] == nil)
  local printed, stringed = case.scoped.globals["print"], case.scoped.globals["string"]
  assert(printed ~= nil and #printed == 1 and stringed ~= nil and #stringed == 1 and case.scoped.globals["thread"] == nil)
  local e = one_error("print(nothing)")
  assert(e.code == "unknown_variable" and e.y == 1 and e.x == 7)
  assert(e.msg == "`nothing` is not declared")
  assert(e.fix == "declare it with `local nothing = ...` above this use, or require its module with " ..
      "`local nothing = require(\"...\")`; a program has no globals except the ones a declaration file declares")
end

local function test_an_unknown_name_is_told_the_nearest_name_in_scope()
  local e = one_error("local counter_total = 1\nprint(counter_totl)")
  assert(e.code == "unknown_variable" and e.y == 2 and e.x == 7)
  assert(e.fix == "if you meant `counter_total` (declared at 1:7), write that; otherwise declare it with " ..
      "`local counter_totl = ...` above this use, or require its module with `local counter_totl = require(\"...\")`; " ..
      "a program has no globals except the ones a declaration file declares")
  local declared = one_error("print(strng.upper(\"a\"))")
  assert(declared.fix:find("if you meant `string`, which is declared for every program, write that;", 1, true) == 1)
  assert(one_error("print(Counter)").fix:find("if you meant `counter`", 1, true) == 1)
  assert(one_error("print(zz)").fix:find("if you meant", 1, true) == nil)
end

local function test_a_name_used_before_its_declaration_is_told_to_move_it()
  local e = one_error("print(later)\nlocal later = 1")
  assert(e.code == "unknown_variable" and e.y == 1 and e.x == 7)
  assert(e.msg == "`later` is used before the variable `later` that is declared at 2:7")
  assert(e.fix == "Lua sees only what is declared above a use: move the declaration of `later` (line 2) above this line, " ..
      "or declare `local later: <its type>` here and assign it where it is declared now")
  assert(place(e) == "2:7")
end

local function test_an_assignment_to_a_name_nothing_declares_is_told_to_declare_it()
  local e = one_error("fresh = 1")
  assert(e.code == "unknown_variable" and e.y == 1 and e.x == 1 and e.msg == "`fresh` is assigned but declared nowhere")
  assert(e.fix == "declare it with `local fresh = ...` above this assignment; a program has no globals except the ones a " ..
      "declaration file declares")
  local writes = scope("fresh = 1").scoped.global_writes["fresh"]
  assert(writes ~= nil and #writes == 1)
  local const = one_error("print = 1")
  assert(const.code == "const_assigned" and const.msg == "the global `print` is declared `<const>` and cannot be assigned")
  assert(const.fix == "keep the new value in a local of your own: `local print_new = ...`")
  assert(errors("counter = 1") == "")
end

local function test_an_unknown_type_is_told_how_to_declare_it()
  local e = one_error("local x: Widgt = nil\nlocal record Widget end")
  assert(e.code == "unknown_type" and e.y == 1 and e.x == 10 and e.msg == "the type `Widgt` is not declared")
  assert(e.fix == "declare it above with `local record Widgt ... end`, `local enum Widgt ... end` or `local type Widgt = ...`, " ..
      "or import it with `local type Widgt = require(\"...\")`; a program may use `any`, `boolean`, `integer`, `never`, " ..
      "`number`, `string` and `thread` with no declaration")
end

local function test_a_declaration_whose_name_is_visible_shadows_it()
  local e = one_error("local x = 1\nlocal x = 2\nprint(x)")
  assert(e.code == "shadows" and e.y == 2 and e.x == 7)
  assert(e.msg == "variable `x` shadows the variable `x` declared at 1:7")
  assert(e.fix == "to change the existing `x` write `x = ...` without `local`; to keep both, rename the new one")
  assert(place(e) == "1:7")
  assert(errors("local x = 1\ndo local x = 2 print(x) end") == "shadows 2:10")
  assert(errors("local x = 1\nlocal function f(x) return x end") == "shadows 2:18")
  assert(errors("local x = 1\nfor x = 1, 2 do print(x) end") == "shadows 2:5")
  assert(errors("local x = 1\nlocal t = { f = function(x) return x end }") == "shadows 2:26")
  assert(errors("local x, x = 1, 2") == "shadows 1:10")
  assert(errors("local x = 1\nrepeat local x = 2 until x") == "shadows 2:14")
end

local function test_a_shadow_of_a_variable_of_another_function_is_told_to_rename()
  local e = one_error("local x = 1\nlocal function f() local x = 2 return x end")
  assert(e.code == "shadows" and e.y == 2 and e.x == 26)
  assert(e.fix == "rename the new `x` (the old one is declared at 1:7 and stays visible if this one has another name)")
end

local function test_a_declaration_that_hides_a_declared_global_shadows_it()
  local e = one_error("local print = 1\nprint = 2")
  assert(e.code == "shadows" and e.y == 1 and e.x == 7 and place(e) == "none")
  assert(e.msg == "variable `print` shadows the global `print`")
  assert(e.fix == "rename it: it would hide the declared global `print` for the rest of its scope. " ..
      "To keep the global under its name in a local, write `local print = print`")
  assert(errors("local string = string\nprint(string)") == "")
  assert(errors("local thread = 1\nprint(thread)") == "")
end

local function test_some_declarations_do_not_shadow()
  assert(errors("local x = 1\nlocal x = x\nprint(x)") == "")
  assert(errors("local _x = 1\nlocal _x = 2\nprint(_x)") == "")
  assert(errors("local class A\n  function m(self) return self end\nend\nlocal class B\n  function m(self) return self end\nend") == "")
  assert(errors("local record A\n  record Inner n: integer end\nend\nlocal record B\n  record Inner n: integer end\nend") == "")
  assert(errors("local record Options n: integer end\nlocal record Other\n  record Options m: integer end\nend") == "")
  assert(errors("local function f() end\nlocal function g() local function h() end return h end\nprint(f, g)") == "")
  assert(errors("local x = 1\ndo local y = x end\ndo local y = x end") == "")
end

local function test_the_parameters_of_a_local_function_do_not_shadow_its_name()
  assert(errors("local function f(f) return f end") == "")
  assert(errors("local function f<f>(x: f) return x end") == "")
  assert(errors("local f = 1\nlocal function f(f) return f end") == "shadows 2:16; shadows 2:18")
  assert(errors("local function f() local f = 1 return f end") == "shadows 1:26")
end

local function test_a_type_parameter_that_hides_a_name_is_told_to_rename_it()
  local e = one_error("local record T end\nlocal function f<T>(x: T) return x end")
  assert(e.code == "shadows" and e.y == 2 and e.x == 18)
  assert(e.fix == "rename the type parameter: it hides the record `T` in scope here")
end

local function test_env_is_reserved()
  local e = one_error("local _ENV = {}")
  assert(e.code == "env_reserved" and e.y == 1 and e.x == 7 and e.msg == "`_ENV` is reserved and cannot be declared")
  assert(e.fix == "choose another name for the variable")
  assert(errors("local function f(_ENV) end") == "env_reserved 1:18")
end

local function test_a_function_may_assign_a_local_outside_it_and_the_local_is_marked()
  local function marked(source: string, name: string): boolean
    local parsed = Parser.parse(Lexer.lex(source, "f.tl"), "f.tl", "tl")
    local scoped = Scopes.build(parsed.chunk, "f.tl", GLOBALS)
    assert(#scoped.errors == 0, source)
    for _, v in ipairs(scoped.list) do
      if v.name == name then
        return v.closure_assigned
      end
    end
    error("no local " .. name)
  end
  assert(marked("local n = 0\nlocal function bump() n = n + 1 end\nbump()", "n"))
  assert(marked("local n = 0\nlocal t = { f = function() n = 1 end }", "n"))
  assert(marked("local n = 0\nlocal function a() local function b() n = 1 end b() end a()", "n"))
  -- The mark is made wherever the function is: before a read of the local, and in a loop.
  assert(marked("local n = 0\nprint(n)\nfor i = 1, 2 do local f = function() n = i end f() end", "n"))
  -- A write by the function that declares it, a parameter that shadows, and a write to a field are not marked.
  assert(not marked("local n = 0\nn = 1\nprint(n)", "n"))
  assert(not marked("local n = 0\nlocal function f() local m = n m = 2 return m end f()", "n"))
  assert(errors("local n = 0\nlocal function f(n) n = 1 end f(0)") == "shadows 2:18")
  assert(not marked("local box = { n = 0 }\nlocal function f() box.n = 1 end f()", "box"))
  -- A write by a function leaves the capture of the local after it as the writes of its own function make it.
  assert(errors("local n = 0\nlocal function f() n = 1 end f()\nn = 2") == "")
  assert(errors("local n <const> = 0\nlocal function f() n = 1 end f()") == "const_assigned 2:20")
end

local function test_what_is_assigned_and_read_is_recorded_for_each_variable()
  local case = scope("local a, b, c = 1, 2, 3\na = b\nb = a\nprint(a, c)")
  assert(var(case, "a").assigned and #var(case, "a").writes == 1 and #var(case, "a").reads == 2)
  assert(var(case, "b").assigned and #var(case, "b").reads == 1)
  assert(not var(case, "c").assigned and #var(case, "c").reads == 1 and #var(case, "c").captures == 0)
  assert(var(case, "a").owner == 1 and var(case, "a").depth == 1 and var(case, "a").top and var(case, "a").loop == 0)
end

local function test_a_capture_says_whether_an_assignment_may_follow_the_function()
  local before = scope("local x = 1\nx = 2\nlocal function f() return x end\nprint(f)")
  assert(var(before, "x").assigned and #var(before, "x").captures == 1 and not capture(before, "x", 1).after)
  local after = scope("local x = 1\nlocal function f() return x end\nx = 2\nprint(f)")
  assert(capture(after, "x", 1).after)
  local same = scope("local x, f = 1, nil\nx, f = 2, function() return x end\nprint(f)")
  assert(capture(same, "x", 1).after)
  local none = scope("local x = 1\nlocal function f() return x end\nprint(f)")
  assert(#var(none, "x").captures == 1 and not var(none, "x").assigned and not capture(none, "x", 1).after)
end

local function test_an_assignment_earlier_in_a_loop_follows_a_function_made_later_in_it()
  local looped = scope("local x = 1\nfor i = 1, 3 do\n  x = i\n  local f = function() return x end\n  print(f)\nend")
  assert(looped.scoped.errors[1] == nil and capture(looped, "x", 1).after)
  local fresh = scope("for i = 1, 3 do\n  local x = 1\n  x = i\n  local f = function() return x end\n  print(f)\nend")
  assert(not capture(fresh, "x", 1).after, "each iteration has a variable of its own")
  local inner = scope("local x = 1\nx = 2\nfor i = 1, 3 do\n  local f = function() return x end\n  print(f)\nend")
  assert(not capture(inner, "x", 1).after, "the assignment is outside the loop")
  local repeated = scope("local x = 1\nrepeat\n  x = 2\n  local f = function() return x end\n  print(f)\nuntil x")
  assert(capture(repeated, "x", 1).after)
end

local function test_a_function_inside_a_function_captures_through_the_outer_one()
  local case = scope("local x = 1\nlocal function f()\n  return function() return x end, function() return x end\nend\nx = 2\nprint(f)")
  local x = var(case, "x")
  assert(#x.captures == 1 and #x.captures[1].uses == 2 and x.captures[1].after)
  local two = scope("local x = 1\nlocal function f() return x end\nlocal function g() return x end\nprint(f, g)")
  assert(#var(two, "x").captures == 2 and capture(two, "x", 1).fn ~= capture(two, "x", 2).fn)
end

local function test_a_copy_of_a_name_is_recorded()
  local case = scope("local x = 1\nlocal x = x\nlocal y = x\nprint(y)")
  assert(var(case, "x", 2).copies == var(case, "x", 1).id and var(case, "y").copies == nil)
  local printed = scope("local print = print").scoped.list[1]
  assert(printed ~= nil and printed.copies == nil)
end

local function test_the_refused_colon_form_has_a_self()
  local case = scope("local record R end\nfunction R:m() return self end")
  assert(var(case, "self").kind == "param" and #var(case, "self").reads == 1)
end

local function test_a_declaration_file_declares_its_globals_including_those_in_a_do_block()
  local source = "do\n  local record Hidden end\n  global record io\n    open: function(): Hidden\n  end\n  global print <const> = 1\nend\n" ..
    "global arg: string"
  local parsed = Parser.parse(Lexer.lex(source, "d.d.tl"), "d.d.tl", "decl")
  local declared = Scopes.declared(parsed.chunk)
  local io, printed = declared["io"], declared["print"]
  assert(io ~= nil and io.space == "both" and not io.const)
  assert(printed ~= nil and printed.const and declared["arg"] ~= nil)
  assert(declared["Hidden"] == nil)
end

local function test_in_scope_answers_the_innermost_binding_at_a_token()
  local source = "local x = 1\nlocal function f(x, y)\n  return x\nend\nlocal z = 2"
  local case = scope(source)
  local function token_at(y: integer, x: integer): integer
    for i, ty in ipairs(case.tokens.y) do
      if ty == y and Lexer.x(case.tokens, i) == x then
        return i
      end
    end
    error("no token")
  end
  local inside = Scopes.in_scope(case.scoped, token_at(3, 10))
  assert(inside.x == var(case, "x", 2) and inside.y == var(case, "y") and inside.f == var(case, "f"))
  assert(inside.z == nil)
  local outside = Scopes.in_scope(case.scoped, token_at(5, 7))
  assert(outside.x == var(case, "x", 1) and outside.y == nil and outside.z == nil)
  assert(Scopes.in_scope(case.scoped, #case.tokens.kind).z == var(case, "z"))
end

local function test_building_twice_gives_the_same_bindings()
  local source = "local x = 1\nlocal function f(a) return a + x + counter end\nprint(f)"
  local case = scope(source)
  local first = Scopes.build(case.parsed.chunk, "t.tl", GLOBALS)
  local again = Scopes.build(case.parsed.chunk, "t.tl", GLOBALS)
  assert(#first.list == #again.list and #first.errors == #again.errors)
  for id, bound in pairs(first.resolved) do
    assert(again.resolved[id] == bound)
  end
end

local function test_a_name_that_was_bound_is_unbound_when_the_globals_change()
  local parsed = Parser.parse(Lexer.lex("print(x)", "t.tl"), "t.tl", "tl")
  local with: {string: Scopes.Global} = { print = GLOBALS.print, x = { space = "value", const = false } }
  assert(#Scopes.build(parsed.chunk, "t.tl", with).errors == 0)
  assert(#Scopes.build(parsed.chunk, "t.tl", {}).errors == 2)
end

local function test_errors_come_in_source_order_with_a_message_and_a_fix()
  local source = "print(a)\nlocal x = 1\nlocal x = 2\nprint(b)\nlocal y: T = x\nx = 1"
  local list = scope(source).scoped.errors
  assert(#list == 4)
  local at_offset = 0
  for _, e in ipairs(list) do
    assert(e.offset > at_offset and e.msg ~= "" and e.fix ~= "" and e.filename == "t.tl")
    at_offset = e.offset
  end
end

local function test_a_chain_of_any_length_is_walked()
  local source = "local a = 1\nlocal b = a" .. (" + a"):rep(20000) .. "\nlocal c = b" .. (".f"):rep(20000) .. "\n" ..
    "local d = print" .. ("()"):rep(20000)
  local case = scope(source)
  assert(case.scoped.errors[1] == nil and #var(case, "a").reads == 20001)
  local deep = "local x = 1\nlocal y = " .. ("("):rep(150) .. "x" .. (")"):rep(150)
  assert(#var(scope(deep), "x").reads == 1)
end

local function test_a_function_in_an_assignment_target_does_not_hide_the_assignment_that_follows_a_function_in_it()
  -- The function in the first target assigns `y` and ends its own statement; `x` is assigned by the outer one.
  local source = "local x = 0\nlocal t = {}\nt[function() local y = 1 y = 2 end], x, t[2] = 1, 2, function() return x end"
  local case = scope(source)
  assert(case.scoped.errors[1] == nil)
  assert(#var(case, "x").captures == 1 and capture(case, "x", 1).after)
end

local function test_a_type_of_a_signature_is_declared_outside_the_function_not_among_its_locals()
  local source = "local function f(x: T)\n  local T = require(\"m\")\n  return T\nend\nlocal record T\n  n: integer\nend"
  local case = scope(source)
  assert(case.scoped.errors[1] == nil, errors(source))
  assert(#var(case, "T", 1).type_uses == 0 and #var(case, "T", 2).type_uses == 1)
  assert(var(case, "T", 2).kind == "record")
  local param = "local function f(T: integer, x: T) return T end\nlocal record T\n  n: integer\nend"
  assert(errors(param) == "", errors(param))
  local bound = scope(param)
  assert(#var(bound, "T", 2).type_uses == 1 and #var(bound, "T", 1).type_uses == 0)
  assert(errors("local function f<T>(x: T, y: U): T\n  local U = 1\n  return x\nend") == "unknown_type 1:30")
end

local function test_a_type_is_refused_a_primitive_types_name_with_the_fix_to_rename_it()
  local e = one_error("local record number\n  n: integer\nend")
  assert(e.code == "primitive_type_name" and e.y == 1 and e.x == 14)
  assert(e.msg == "`number` is a primitive type, so a record of that name could never be named")
  assert(e.fix == "rename the record, for example to `Number`: in a type, `number` always means the primitive")
  assert(errors("local function f<integer>(x: integer) end") == "primitive_type_name 1:18")
  assert(errors("local enum number \"a\" end") == "primitive_type_name 1:12")
  assert(errors("local type any = integer") == "primitive_type_name 1:12")
  assert(errors("local class boolean\nend") == "primitive_type_name 1:13")
  assert(errors("local interface never\nend") == "primitive_type_name 1:17")
  assert(errors("local function integer() end\nlocal integer = 1\nlocal x = integer") == "shadows 2:7")
end

local function test_a_local_is_the_head_of_a_type_only_if_it_holds_a_module()
  local value = one_error("local n = 1\nlocal y: n.T = nil")
  assert(value.code == "not_a_type" and value.y == 2 and value.x == 10)
  assert(value.msg == "`n` is a variable, a value, and names no type")
  assert(value.fix == "write a type here: declare it with `local record n ... end`, `local type n = ...` or import it with " ..
      "`local type n = require(\"...\")`")
  local alias = one_error("local Rules = require(\"rules\")\nlocal Seatbelt = Rules.Seatbelt\nlocal y: Seatbelt.Grant = nil")
  assert(alias.code == "not_a_type" and alias.y == 3 and alias.x == 10)
  assert(alias.fix == "declare the type instead of the variable: `local type Seatbelt = Rules.Seatbelt`")
  assert(errors("local Rules = require(\"rules\")\nlocal y: Rules.Seatbelt.Grant = nil") == "")
  assert(errors("local type Seatbelt = require(\"rules\")\nlocal y: Seatbelt.Grant = nil") == "")
end

local function test_a_shadow_of_a_function_a_record_or_a_class_is_told_to_rename()
  local fix = "rename the new `f` (the old one is declared at 1:7 and stays visible if this one has another name)"
  assert(one_error("local f = 1\nlocal function f() end").fix == fix)
  assert(one_error("local f = 1\nlocal record f\nend").fix == fix)
  assert(one_error("local f = 1\nlocal class f\nend").fix == fix)
  assert(one_error("local f = 1\nlocal f = 2").fix:find("write `f = ...` without `local`", 1, true) ~= nil)
end

local function test_the_alias_fix_is_offered_only_where_the_chain_starts_at_a_module_or_a_type()
  local generic = "write a type here: declare it with `local record n ... end`, `local type n = ...` or import it with " ..
    "`local type n = require(\"...\")`"
  assert(one_error("local cfg = {}\nlocal n = cfg.count\nlocal y: n.T = nil").fix == generic)
  assert(one_error("local n = string.len\nlocal y: n.T = nil").fix == generic)
  assert(one_error("local record R\nend\nlocal n = R.Inner\nlocal y: n.T = nil").fix ==
      "declare the type instead of the variable: `local type n = R.Inner`")
end

local function test_a_declaration_with_a_primitives_name_gives_that_error_alone()
  assert(errors("local type string = number") == "primitive_type_name 1:12")
  assert(errors("local record thread\nend") == "primitive_type_name 1:14")
end
