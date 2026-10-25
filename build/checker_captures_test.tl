--- A function literal does not assign a local declared outside it
--- ([`checker/captures.tl`]): the checker refuses each such assignment with
--- the code `captured_assigned`, and [`build.teal`] tells the rewrite. Each
--- form of function (a literal, a `local function`, `function f()`, a record
--- function or method) is held on both sides: one that assigns an outside
--- local is refused, and one that reads it, writes a field of what it holds,
--- or assigns what it declares is accepted.
local type compiler = require("build.compiler")
local teal = require("build.teal")

--- The type errors the checker reports for `source`.
local function type_errors(source: string): {compiler.Error}
  local built = assert(teal.load(true))
  local _, result = built.gen(source, nil, nil, "tl")
  return assert(result).type_errors
end

--- What every program here is written against.
local head <const> = "local record R\n  n: integer\nend\nlocal function use(_: any) end\n" ..
  "local function each(f: function()) f() end\n"

--- The messages of `errors`, one to a line.
local function shown(errors: {compiler.Error}): string
  local lines: mut {string} = {}
  for _, e in ipairs(errors) do
    lines[#lines + 1] = tostring(e.y) .. ":" .. tostring(e.x) .. " " .. tostring(e.code) .. " " .. e.msg
  end
  return table.concat(lines, "\n")
end

--- Holds `body`, statements after [`head`], to be accepted.
local function accepts(body: string)
  local errors = type_errors(head .. body .. "\n")
  assert(#errors == 0, shown(errors) .. "\n" .. body)
end

--- Holds `body` to be refused once, for an assignment to `name`, and
--- answers that error.
local function refuses(body: string, name: string): compiler.Error
  local errors = type_errors(head .. body .. "\n")
  assert(#errors == 1, shown(errors) .. "\n" .. body)
  local e = errors[1]
  assert(e.code == "captured_assigned" and e.variable == name, shown(errors) .. "\n" .. body)
  return e
end

--- The lines of [`head`].
local function lines_of(text: string): integer
  local _, count = text:gsub("\n", "\n")
  return count
end

local head_lines <const> = lines_of(head)

--- The message of a refusal of an assignment to `name`.
local function message(name: string): string
  return "'" .. name .. "' is a local of the code around this function, which a function may read but not assign"
end

--- The refusal names the variable, the assignment and the declaration.
local function test_a_refusal_names_the_variable_the_assignment_and_the_declaration()
  local e = refuses("local n = 0\nuse(function() n = n + 1 end)", "n")
  assert(e.msg == message("n"), e.msg)
  -- At the name assigned: the second line after the head, column 16.
  assert(e.y == head_lines + 2 and e.x == 16, tostring(e.y) .. ":" .. tostring(e.x))
  -- Declared on the line before, at the column of the name.
  assert(e.declared_y == head_lines + 1 and e.declared_x == 7,
    tostring(e.declared_y) .. ":" .. tostring(e.declared_x))
end

--- The hint says to return the value or keep it in a field both read.
local function test_the_hint_says_to_return_the_value_or_keep_it_in_a_table()
  local source = head .. "local got = 0\neach(function() got = 1 end)\nuse(got)\n"
  local errors = type_errors(source)
  assert(#errors == 1, shown(errors))
  local hint = assert(teal.replacement(errors[1], source), errors[1].msg)
  assert(hint == "'got' is declared at " .. tostring(head_lines + 1) .. ":7, outside this function, " ..
      "which may read it but not assign it: return the value from the function, or keep it in a field " ..
      "of a table both read (`local held = { got = <the value> }`, then `held.got = ...` in the function)",
    hint)
end

--- Each form of function is a function.
local function test_every_form_of_function_is_refused_for_assigning_an_outside_local()
  refuses("local n = 0\nuse(function() n = 1 end)", "n")
  refuses("local n = 0\nlocal function bump() n = 1 end\nuse(bump)", "n")
  refuses("local n = 0\nlocal bump = function() n = 1 end\nuse(bump)", "n")
  -- A record function and a method.
  refuses("local n = 0\nfunction R.reset() n = 1 end", "n")
  refuses("local n = 0\nfunction R:reset() n = 1 end", "n")
  -- A function typed by a declaration made before it, and one assigned to a field.
  refuses("local n = 0\nlocal t: {string:function()} = {}\nt.bump = function() n = 1 end\nuse(t)", "n")
  refuses("local n = 0\nuse({ bump = function() n = 1 end })", "n")
  -- `function f()` for a local `f` declared before it assigns that local, so
  -- inside another function it is an assignment to an outside local.
  refuses("local f: function() = function() end\nlocal function make() function f() end end\nuse(make)", "f")
end

--- A function names the local it is.
local function test_a_function_that_assigns_its_own_name_assigns_an_outside_local()
  refuses("local function again() again = nil end\nuse(again)", "again")
end

--- Nesting does not hide the declaration.
local function test_an_assignment_from_a_nested_function_is_refused_through_any_number_of_levels()
  refuses("local n = 0\nuse(function() use(function() n = 1 end) end)", "n")
  refuses("local n = 0\nuse(function() use(function() use(function() n = 1 end) end) end)", "n")
  -- Declared in the middle function: the inner one assigns a local of the outer.
  refuses("use(function()\n  local m = 0\n  use(function() m = 1 end)\nend)", "m")
  -- A function in a function assigning the outermost and an intermediate local: two refusals.
  local errors = type_errors(head .. "local a = 0\nuse(function()\n  local b = 0\n  use(function() a, b = 1, 2 end)\nend)\n")
  assert(#errors == 2 and errors[1].variable == "a" and errors[2].variable == "b", shown(errors))
end

--- The assignment may be anywhere in the function.
local function test_an_assignment_in_any_statement_of_the_function_is_refused()
  refuses("local n = 0\nuse(function() for _ = 1, 3 do n = n + 1 end end)", "n")
  refuses("local n = 0\nuse(function() while n < 3 do n = n + 1 end end)", "n")
  refuses("local n = 0\nuse(function() repeat n = n + 1 until n > 2 end)", "n")
  refuses("local n = 0\nuse(function() for _, v in ipairs({ 1 }) do n = v end end)", "n")
  refuses("local n = 0\nuse(function() if n == 0 then n = 1 end end)", "n")
  refuses("local n = 0\nuse(function() do n = 1 end end)", "n")
  refuses("local n = 0\nuse(function(): integer\n  n = 1\n  return n\nend)", "n")
  -- Each target of a multiple assignment is its own refusal.
  local errors = type_errors(head .. "local a, b = 0, 0\nuse(function() a, b = b, a end)\n")
  assert(#errors == 2 and errors[1].variable == "a" and errors[2].variable == "b", shown(errors))
  -- Every assignment is, not the first alone.
  errors = type_errors(head .. "local n = 0\nuse(function() n = 1 n = 2 end)\n")
  assert(#errors == 2, shown(errors))
end

--- A function is found wherever an expression stands.
local function test_a_function_in_any_expression_position_is_refused()
  local make = "(function(): boolean n = 1 return true end)()"
  refuses("local n = 0\nrepeat\nuntil " .. make, "n")
  refuses("local n = 0\nwhile " .. make .. " do break end", "n")
  refuses("local n = 0\nif " .. make .. " then use(1) end", "n")
  refuses("local n = 0\nif n == 1 then use(1) elseif " .. make .. " then use(2) end", "n")
  refuses("local n = 0\nfor _ = 1, (function(): integer n = 1 return 2 end)() do use(1) end", "n")
  refuses("local n = 0\nfor _ in ipairs((function(): {integer} n = 1 return {} end)()) do use(1) end", "n")
  refuses("local n = 0\nlocal r = " .. make .. "\nuse(r)", "n")
  refuses("local n = 0\nlocal function f(): boolean return " .. make .. " end\nuse(f)", "n")
  refuses("local n = 0\nuse({ " .. make .. " })", "n")
  refuses("local n = 0\nlocal macroexp make(): boolean return " .. make .. " end\nuse(make())", "n")
  -- The condition of a `repeat` sees the locals of its body.
  refuses("repeat\n  local q = 1\n  use(q)\nuntil (function(): boolean q = 2 return true end)()", "q")
end

--- A type declaration holds expressions too: its `where` clause.
local function test_a_function_in_a_where_clause_is_refused_like_any_other()
  local make = "(function(): boolean n = 1 return true end)()"
  refuses("local n = 0\nlocal record W where " .. make .. " and self ~= nil\n  x: integer\nend\nuse(W)", "n")
  refuses("local n = 0\nglobal record G where " .. make .. "\n  x: integer\nend", "n")
  refuses("local n = 0\nlocal interface I where " .. make .. "\n  x: integer\nend", "n")
  -- A record nested in another, and one nested two deep, have their own clauses.
  refuses("local n = 0\nlocal record W\n  record In where " .. make .. "\n    y: integer\n  end\n  x: integer\nend\nuse(W)", "n")
  refuses("local n = 0\nlocal record W\n  record In\n    record Deep where " .. make ..
      "\n      y: integer\n    end\n  end\nend\nuse(W)", "n")
  -- The program that crashes if it is taken: the clause clears what the test just found.
  refuses("local nn: integer | nil = 5\nlocal record W where (function(): boolean nn = nil return true end)() and self ~= nil\n" ..
      "  x: integer\nend\nlocal v: any = { x = 1 }\nif nn then\n  local ok = v is W\n  use(ok)\n  use(nn + 1)\nend", "nn")
  -- What it reads, and what it declares, are its own to use.
  accepts("local n = 0\nlocal record W where (function(): boolean return n == 0 end)()\n  x: integer\nend\nuse(W)")
  accepts("local record W where (function(): boolean local k = 0 k = 1 return k == 1 end)()\n  x: integer\nend\nuse(W)")
  accepts("local record W where self.x > 0\n  x: integer\nend\nuse(W)")
end

--- The hint's table has a name of its own.
local function test_the_hint_names_its_table_apart_from_the_variable()
  for _, name in ipairs({ "state", "held" }) do
    local source = head .. "local " .. name .. " = 0\neach(function() " .. name .. " = 1 end)\nuse(" .. name .. ")\n"
    local errors = type_errors(source)
    assert(#errors == 1, shown(errors))
    local hint = assert(teal.replacement(errors[1], source), errors[1].msg)
    local table_name = if name == "held" then "box" else "held" end
    assert(hint:find("(`local " .. table_name .. " = { " .. name .. " = <the value> }`, then `" ..
        table_name .. "." .. name .. " = ...` in the function)", 1, true), hint)
  end
end

--- The kinds of local the rule is about.
local function test_a_parameter_and_a_loop_variable_are_locals_too()
  refuses("local function counter(n: integer)\n  use(function() n = n + 1 end)\nend\nuse(counter)", "n")
  refuses("for i = 1, 3 do\n  use(function() i = 0 end)\nend", "i")
  refuses("for _, v in ipairs({ 1 }) do\n  use(function() v = 0 end)\nend", "v")
  -- A method's `self`, and a local declared with no value.
  refuses("function R:each()\n  use(function() self = nil end)\nend", "self")
  refuses("local pending: integer | nil\nuse(function() pending = 1 end)", "pending")
end

--- Reading is the function's to do.
local function test_a_function_may_read_what_is_around_it()
  accepts("local n = 0\nuse(function(): integer return n + 1 end)")
  accepts("local n = 0\nlocal function show() use(n) end\nshow()")
  accepts("local n = 0\nuse(function() use(function() use(n) end) end)")
  -- A name only looks like the local: a field, a key, a type, a string.
  accepts("local n = 0\nuse(function() local t: R = { n = 1 } use(t.n) t.n = n end)")
  accepts("local n = 0\nuse(function() use({ n = 1 }) end)")
  -- A comparison is no assignment.
  accepts("local n = 0\nuse(function(): boolean return n == 1 end)")
  accepts("local macroexp positive(x: integer): boolean return x > 0 end\nlocal n = 1\nuse(function(): boolean return positive(n) end)")
end

--- The rule is about the binding, not what it holds.
local function test_a_function_may_write_a_field_of_a_table_it_holds()
  accepts("local state = { n = 0 }\nuse(function() state.n = state.n + 1 end)")
  accepts("local state: R = { n = 0 }\nlocal function bump() state.n = state.n + 1 end\nbump()")
  accepts("local list: {integer} = {}\nuse(function() list[#list + 1] = 1 end)")
  accepts("local map: {string:integer} = {}\nuse(function() map[\"a\"] = 1 end)")
  accepts("local state = { inner = { n = 0 } }\nuse(function() state.inner.n = 1 end)")
  -- And through a nested function.
  accepts("local state = { n = 0 }\nuse(function() use(function() state.n = 1 end) end)")
end

--- Its own are its to assign.
local function test_a_function_may_assign_what_it_declares_and_its_parameters()
  accepts("use(function() local n = 0 n = n + 1 use(n) end)")
  accepts("use(function(n: integer): integer n = n + 1 return n end)")
  accepts("use(function(n: integer) for i = 1, n do use(i) end end)")
  accepts("use(function() local a, b = 0, 0 a, b = b, a use(a) use(b) end)")
  accepts("use(function() for _, v in ipairs({ 1 }) do v = 0 use(v) end end)")
  -- A nested function assigns the nested function's own.
  accepts("use(function()\n  local m = 0\n  use(function() local m = 1 m = 2 use(m) end)\n  m = 3\n  use(m)\nend)")
  accepts("use(function(n: integer) use(function(n: integer) n = 1 use(n) end) n = 2 use(n) end)")
  -- A local function recursing by name reads it.
  accepts("local function down(n: integer): integer if n == 0 then return 0 end return down(n - 1) end\nuse(down)")
end

--- A name a local of the function hides is not the outside one.
local function test_a_local_that_shadows_the_outside_one_is_the_functions_own()
  accepts("local n = 0\nuse(function() local n = 1 n = 2 use(n) end)\nuse(n)")
  accepts("local n = 0\nuse(function(n: integer) n = 2 use(n) end)\nuse(n)")
  accepts("local n = 0\nuse(function() for n = 1, 2 do use(n) end end)\nuse(n)")
  -- A shadow that begins after the assignment hides nothing before it.
  refuses("local n = 0\nuse(function()\n  n = 1\n  local n = 2\n  use(n)\nend)", "n")
  -- A shadow in a block ends with it.
  refuses("local n = 0\nuse(function()\n  do local n = 1 use(n) end\n  n = 2\nend)", "n")
  -- The initial value of a shadow is read in the scope before it.
  accepts("local n = 0\nuse(function() local n = n + 1 n = n + 1 use(n) end)")
end

--- Outside any function, a local is assigned freely.
local function test_code_outside_any_function_assigns_locals_freely()
  accepts("local n = 0\nn = n + 1\nfor i = 1, 3 do n = n + i end\nuse(n)")
  accepts("local n = 0\ndo n = 1 end\nif n == 1 then n = 2 end\nuse(n)")
  -- The forward declaration: assigned outside a function, then read by one.
  accepts("local f: function()\nf = function() use(f) end\nf()")
  accepts("local f: function(): integer\nlocal function g(): integer return f() end\nf = function(): integer return 1 end\nuse(g)")
  -- `function f()` for a local `f` made outside any function.
  accepts("local f: function()\nfunction f() use(f) end\nf()")
  accepts("local handler: function(integer)\nfunction handler(n: integer) use(n) end\nhandler(1)")
end

--- A global is not followed.
local function test_a_global_is_not_a_local()
  accepts("global total: integer = 0\nuse(function() total = total + 1 end)")
  accepts("global function tick() end\nuse(function() tick = nil end)")
end

--- The first function is the one whose body assigns.
local function test_each_assignment_is_refused_at_the_function_that_makes_it()
  local errors = type_errors(head .. "local n = 0\nuse(function() n = 1 end)\nuse(function() n = 2 end)\nn = 3\n")
  assert(#errors == 2 and errors[1].y == head_lines + 2 and errors[2].y == head_lines + 3, shown(errors))
end
