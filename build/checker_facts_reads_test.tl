--- What the checker's facts (`self.facts`, checker/facts.tl) make of a read,
--- as the verdicts of small programs: a use after an assignment or in a loop
--- is told the assignment, a `local x = x` keeps its type past a function
--- declaration, unreachable code is checked from the facts at the jump, and a
--- function literal reads the binding it was made over.
local Test = require("cosmic.test")
local teal = require("build.teal")
local verdicts = require("build.checker_verdicts")
local type compiler = require("build.compiler")

Test.policy{}

local built = { value = nil as compiler? }

--- The tree's checker, loaded once.
local function checker(): compiler
  if built.value == nil then
    built.value = assert(teal.load(true))
  end
  return built.value
end

--- The verdict of `text` as a program of its own, the lines of
--- [`build.checker_verdicts`] joined.
local function verdict(file: string, text: string): string
  return (verdicts.render(verdicts.program_lines(checker(), file, text)))
end

--- A `local x = x` is a variable of its own: a function declared after it
--- widens the outer `x1` and not the local, which keeps the type it was
--- declared with. A widening by name would reach the local too, and refuse
--- the use.
local function test_a_localized_name_keeps_its_type_past_a_function_declaration()
  assert(verdict("localized.tl", [[
local function f(x1: integer | nil): integer
  if x1 then
    local x1 = x1
    local function p() end
    p()
    return x1 + 1
  end
  return 0
end
return f
]]) == "")
end

--- A use of a local that an assignment gave a type that tells nothing (an
--- optional value) is told that the assignment dropped what a test established,
--- wherever the test was: here a test that ends the block, in the scope of the
--- assignment.
local function test_a_use_after_an_assignment_is_told_the_assignment()
  assert(verdict("early.tl", [[
local record R
  a: integer | nil
end
local function g(x: integer | nil, r: R): integer
  if x == nil then
    return 0
  end
  x = r.a
  return x + 1
end
return g
]]) == "early.tl\ttype.narrowing_dropped\t9\t12\tcannot use operator '+' for types integer | nil and integer\n")
end

--- A loop that assigns a local drops the test's fact for the whole body: a
--- read before the assignment in it is told the assignment.
local function test_a_read_in_a_loop_is_told_the_assignment_later_in_it()
  assert(verdict("loop.tl", [[
local function id(v: integer | nil): integer | nil
  return v
end
local function g(x: integer | nil): integer
  local sink = 0
  if x then
    local i = 0
    while i < 2 do
      sink = sink + x + 1
      x = id(nil)
      i = i + 1
    end
  end
  return sink
end
return g
]]) == "loop.tl\ttype.narrowing_dropped\t9\t19\tcannot use operator '+' for types integer and integer | nil\n")
end

--- A function declared after the test widens every narrowed name without
--- saying so, and an assignment after that is no drop of a fact the facts hold:
--- a later use is refused plainly (`widen_narrowed` has the TODO).
local function test_a_declaration_that_widened_a_place_is_not_told()
  assert(verdict("declared.tl", [[
local function maybe(): integer | nil
  return nil
end
local function g(x: integer | nil): integer
  local sink = 0
  if x then
    local function get(): integer
      return 1
    end
    x = maybe()
    sink = sink + get() + x
  end
  return sink
end
return g
]]) == "declared.tl\ttype.operator_binary\t11\t25\tcannot use operator '+' for types integer and integer | nil\n")
end

--- Control that cannot reach a statement leaves the facts as they were where
--- it left: a use after a jump reads them.
local function test_unreachable_code_reads_the_facts_at_the_jump()
  assert(verdict("jump.tl", [[
local function f(x: integer | nil): integer
  if x == nil then return 0 end
  do return x + 1 end
  print(x + 1)
end
return f
]]) == "")
end

--- Unreachable code is checked as if control reached it from where it left,
--- and narrows and drops as reached code does: an assignment there is checked
--- against the type the local has by then, a test narrows, and a function
--- literal made there begins from the facts at the jump.
local function test_unreachable_code_is_checked_from_the_facts_at_the_jump()
  assert(verdict("dead.tl", [[
local function use(n: integer) print(n) end
local function f(): integer
  local x: integer | nil = nil
  error("unimplemented")
  x = 1
  return x
end
local function g(y: integer | nil)
  error("todo")
  if y then use(y) end
end
local function h(): integer
  error("a")
  local function k(z: integer | nil): integer
    if z then return z + 1 end
    return 0
  end
  return k(1)
end
return f, g, h
]]) == "")
end

--- An assignment in unreachable code changes what the code after it reads, as
--- it does in reached code.
local function test_unreachable_code_drops_on_an_assignment()
  assert(verdict("dropped.tl", [[
local function f(x: integer | nil): integer
  if x then
    do return 1 end
    x = nil
    print(x + 1)
  end
  return 0
end
return f
]]) == "dropped.tl\ttype.narrowing_dropped\t5\t13\tcannot use operator '+' for types nil and integer\n")
end

--- A local declared in the scope of a test of the same name is another
--- binding. A function literal made after it reads that binding, not the one
--- the test narrowed: every use below is refused, whatever narrowed the
--- shadowed one (a test that returns, `assert`, an assignment) and whatever
--- uses the shadowing local (a call, arithmetic, a coroutine).
local function test_a_local_declared_over_a_narrowed_name_is_read_by_a_function_literal()
  local head <const> = "local function maybe(): integer | nil return nil end\n" ..
    "local function use(n: integer) print(n) end\n" ..
    "local function t(z: integer | nil, flag: boolean)\n"
  local tail <const> = "end\nreturn t\n"
  local bodies <const>: {string} = {
    "if z == nil then return end\nlocal z: integer | nil = maybe()\nlocal f = function() use(z) end\nf()\nz = nil\n",
    "assert(z)\nlocal z: integer | nil = maybe()\nlocal f = function() use(z) end\nf()\nz = nil\n",
    "z = 1\nlocal z: integer | nil = maybe()\nlocal f = function() use(z) end\nf()\nz = nil\n",
    "if z == nil then return end\nlocal z: integer | nil = maybe()\nlocal f = function() print(z + 1) end\nf()\nz = nil\n",
    "if z == nil then return end\nlocal z: integer | nil = maybe()\n" ..
      "local co = coroutine.wrap(function() coroutine.yield() use(z) end)\nco()\nz = nil\nco()\n",
    "if z == nil then return end\nlocal z: integer | nil = maybe()\nlocal z: integer | nil = maybe()\n" ..
      "local f = function() use(z) end\nf()\nz = nil\n",
    "if z == nil then return end\nlocal z: integer | nil = maybe()\nlocal function f() use(z) end\nf()\nz = nil\n",
    "if flag then\n  if z == nil then return end\n  local z: integer | nil = maybe()\n" ..
      "  local f = function() use(z) end\n  f()\n  z = nil\nend\n",
    "assert(z)\nlocal z: integer | nil = maybe()\nlocal f = function() use(z) end\nf()\nif z then z = nil end\n",
  }
  for n, body in ipairs(bodies) do
    local found = verdict("shadowed" .. n .. ".tl", head .. body .. tail)
    -- The line of the use inside the function literal.
    local line = 0
    local at = 0
    for text in (head .. body):gmatch("([^\n]*)\n") do
      at = at + 1
      if line == 0 and at > 3 and (text:find("use(z)", 1, true) or text:find("z + 1", 1, true)) then
        line = at
      end
    end
    local refused = false
    for entry in found:gmatch("[^\n]+") do
      local code, y = entry:match("^[^\t]*\t(type%.[^\t]*)\t(%d+)\t")
      refused = refused or (code ~= nil and tonumber(y) == line)
    end
    assert(refused, "case " .. n .. " is not refused at " .. line .. ":\n" .. found)
  end
  -- A parameter redeclared in the body of the function that tests it.
  assert(verdict("param.tl", [[
local function maybe(): integer | nil return nil end
local function use(n: integer) print(n) end
local g = function(z: integer | nil)
  if z == nil then return end
  local z: integer | nil = maybe()
  local f = function() use(z) end
  f()
  z = nil
end
g(1)
]]):find("\ttype%.mismatch\t6\t", 1) ~= nil)
  -- The name tested, redeclared and tested again is the new binding's own.
  assert(verdict("again.tl", [[
local function maybe(): integer | nil return nil end
local function use(n: integer) print(n) end
local function t(z: integer | nil)
  if z == nil then return end
  local z: integer | nil = maybe()
  if z == nil then return end
  local f = function() use(z) end
  f()
end
return t
]]):find("\ttype%.", 1) == nil)
end

--- A read of a local credits that local, not the variable of the same name
--- it shadows: the global `G` here is read nowhere, and the local `G` is.
local function test_a_read_credits_the_local_not_the_variable_it_shadows()
  assert(verdict("shadow.tl", [[
global G: integer | nil = 1
local sink: integer = 0
do
  local G: integer | nil = 2
  sink = sink + (G or 0)
end
return sink
]]) == "shadow.tl\twarning.shadows\t4\t9\tvariable shadows previous declaration of 'G'\n")
end

--- A warning about a local shows the type the facts hold of it where its
--- scope ends: here the type of the value its declaration narrowed it to.
local function test_an_unused_warning_shows_the_type_the_declaration_narrowed_to()
  assert(verdict("unused.tl", [[
local function f()
  local x: integer | nil = 1
end
return f
]]) == "unused.tl\twarning.unused\t2\t9\tunused variable x: integer (inferred at :2:28)\n")
end

-- A local that a test or an assignment narrowed in the scope that declares
-- it draws no "written but not read" warning today, though here `x` is
-- written twice and never read. This pins the verdict as it is, not a rule:
-- the TODO at `settle_variables` in checker/tl.tl says what would change it.
local function test_a_local_narrowed_in_its_own_scope_draws_no_never_read_warning()
  assert(verdict("quiet.tl", [[
local function f(a: integer | nil): integer
  local x: integer | nil = a
  x = 1
  x = 2
  return 0
end
return f
]]) == "")
end

--- An assignment to a `local x = x` is held to the type the local was
--- declared with, whatever a function declared after it, or a loop around
--- it, widened of the outer `x`: the local is a variable of its own.
local function test_an_assignment_to_a_localized_name_is_checked_past_a_function_declaration()
  assert(verdict("assigned.tl", [[
local function t(x: integer | string, y: integer | string)
  if x is integer then
    local x = x
    local function g() end
    g()
    x = y
    print(x)
  end
end
return t
]]) == "assigned.tl\ttype.mismatch\t6\t5\tin assignment: got integer | string, expected integer (inferred at :2:8)\n")
end

local function test_an_assignment_to_a_localized_name_is_checked_in_a_loop()
  assert(verdict("looped.tl", [[
local function t(x: integer | string, y: integer | string, z: integer | string)
  if x is integer then
    local x = x
    while z is string do
      x = y
    end
    print(x)
  end
end
return t
]]) == "looped.tl\ttype.mismatch\t5\t7\tin assignment: got integer | string, expected integer (inferred at :2:8)\n")
end

--- A local that shadows a parameter a test narrowed is told where the
--- parameter was declared.
local function test_a_shadowed_narrowed_parameter_is_told_where_it_was_declared()
  assert(verdict("shadowed.tl", [[
local function t(x: integer | nil, z: integer | nil)
  if not x then
    local x = z
    print(x)
  end
end
return t
]]) == "shadowed.tl\twarning.shadows\t3\t11\tvariable shadows previous declaration of 'x' (originally declared at 1:18)\n")
end

--- The warning about a `local x = x` whose value was narrowed shows the type
--- the facts hold of it where its scope ends, as for any other local.
local function test_an_unused_localized_name_shows_its_narrowed_type()
  assert(verdict("localunused.tl", [[
local function t(x: integer | nil)
  if x then
    local x = x
    local function g() end
    g()
  end
end
return t
]]) == "localunused.tl\twarning.unused\t3\t11\tunused variable x: integer (inferred at :2:6)\n")
end

--- A local that shadows a variable a test, an assert or an assignment narrowed
--- is told where that variable was declared, parameter or local.
local function test_a_shadowed_narrowed_local_is_told_where_it_was_declared()
  assert(verdict("shadowedlocal.tl", [[
local function t(z: integer | nil, a: integer | nil)
  local x: integer | nil = a
  if x then
    local x = z
    print(x)
  end
end
return t
]]) == "shadowedlocal.tl\twarning.shadows\t4\t11\tvariable shadows previous declaration of 'x' (originally declared at 2:9)\n")
end

--- A read of a local credits that local, and the shadowed local that is read
--- nowhere is told so: here the outer `v` only.
local function test_a_read_credits_the_inner_local_and_the_outer_one_is_unused()
  assert(verdict("shadowlocal.tl", [[
local function t(a: integer | nil)
  local v: integer | nil = a
  do
    local v: integer | nil = 1
    print(v)
  end
end
return t
]]) == "shadowlocal.tl\twarning.unused\t2\t9\tunused variable v: integer | nil\n" ..
      "shadowlocal.tl\twarning.shadows\t4\t11\tvariable shadows previous declaration of 'v' (originally declared at 2:9)\n")
end

--- A `<const>` or `<close>` local that a test narrowed is still not assigned:
--- Lua refuses such an assignment at load.
local function test_a_narrowed_const_local_cannot_be_assigned()
  assert(verdict("const.tl", [[
local function f(x: integer | string): integer
  local a <const> = x
  if a is integer then
    a = 4
  end
  return 0
end
return f
]]) == "const.tl\ttype.other\t4\t5\tcannot assign to <const> variable\n")
end

local function test_a_narrowed_close_local_cannot_be_assigned()
  assert(verdict("close.tl", [[
local function mk(): table | nil
  return nil
end
local function f()
  local a <close> = mk()
  if a then
    a = nil
  end
end
return f
]]) == "close.tl\ttype.not_closable\t5\t9\tto-be-closed variable a has a non-closable type {<any type> : <any type>} | nil\n" ..
      "close.tl\ttype.other\t7\t5\tcannot assign to <close> variable\n")
end

-- A `local x = x` after a test of `x` has the narrowed type `integer`, which
-- takes a nil today (the TODO above
-- `test_an_assignment_under_a_test_drops_it_and_the_second_name_of_a_declaration_keeps_number`
-- in build/checker_narrowing_test.tl): `x = v` is accepted and `x + 1` is not
-- refused, past a function declaration as without one. This pins today's
-- verdict, not a rule.
local function test_a_nil_assigned_to_a_localized_name_is_used_as_without_the_declaration()
  assert(verdict("nilassigned.tl", [[
local function f(x: integer | nil, v: integer | nil): integer
  if x then
    local x = x
    local function g() end
    g()
    x = v
    return x + 1
  end
  return 0
end
return f
]]) == "")
end
