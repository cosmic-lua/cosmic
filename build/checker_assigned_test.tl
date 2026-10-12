--- A local is assigned before it is read: the checker refuses a local
--- declared with no value (`local x: T`) that some path from its declaration
--- reads before an assignment, and [`build.teal`] tells the rewrite. The
--- refused programs here run, and read nil where the type promised a
--- value. Each form of path (a branch, a loop, a `break`, a `goto`, a
--- return, a call that never returns, a function literal) is held on both
--- sides: a program that assigns on every path is accepted, and one that
--- skips the assignment on a path is refused.
local type compiler = require("build.compiler")
local teal = require("build.teal")

--- The type errors the checker reports for `source`.
local function type_errors(source: string): {compiler.Error}
  local built = assert(teal.load(true))
  local _, result = built.gen(source, nil, nil, "tl")
  return assert(result).type_errors
end

--- What every program here is written against.
local head <const> = "local function use(_: any) end\n" ..
  "local function cond(): boolean return true end\n" ..
  "local function stop(): never error(\"stop\") end\n"

--- `body` as the body of a function after [`head`], which uses no local it
--- does not declare.
local function program(body: string): string
  return head .. "local function f()\n" .. body .. "\nend\nuse(f)\n"
end

--- The messages of `errors`, one to a line.
local function shown(errors: {compiler.Error}): string
  local lines: {string} = {}
  for _, e in ipairs(errors) do
    lines[#lines + 1] = tostring(e.y) .. ":" .. tostring(e.x) .. " " .. tostring(e.code) .. " " .. e.msg
  end
  return table.concat(lines, "\n")
end

--- Holds `body`, a function body, to be accepted.
local function accepts(body: string)
  local source = program(body)
  local errors = type_errors(source)
  assert(#errors == 0, shown(errors) .. "\n" .. source)
end

--- Holds `body` to be refused for reading `name` before it is assigned, once,
--- and answers that error.
local function refuses(body: string, name: string): compiler.Error
  local source = program(body)
  local errors = type_errors(source)
  assert(#errors == 1, shown(errors) .. "\n" .. source)
  local e = errors[1]
  assert(e.code == "not_assigned" and e.variable == name, shown(errors) .. "\n" .. source)
  return e
end

--- The hint [`teal.replacement`] gives `e`, the error of `source`.
local function hint(e: compiler.Error, body: string): string
  return (assert(teal.replacement(e, program(body)), e.msg))
end

local read_msg <const> = "'x' may be read before it is assigned"
local rewrite <const> = ": give it a value where it is declared (`local x: T = ...`), assign it on every path, " ..
  "or declare it `local x: T | nil`, which is nil until assigned and is checked where it is used"

--- Nothing assigned it, and a read.
local function test_a_read_with_no_assignment_before_it_is_refused()
  local e = refuses("local x: integer\nuse(x)", "x")
  assert(e.msg == read_msg and e.closure == nil and e.skipped_kind == nil, e.msg)
  -- At the read: the sixth line of the program, the fifth column.
  assert(e.y == 6 and e.x == 5, tostring(e.y) .. ":" .. tostring(e.x))
  assert(hint(e, "local x: integer\nuse(x)") == read_msg .. rewrite)
  accepts("local x: integer\nx = 1\nuse(x)")
  -- Any use is a read: an operand, an index, a field write through it.
  refuses("local x: integer\nx = x + 1", "x")
  refuses("local x: {integer}\nx[1] = 3", "x")
  refuses("local x: {integer}\nuse(#x)", "x")
  refuses("local x: integer\nuse({ [x] = 1 })", "x")
  -- A field of that name is not the variable.
  accepts("local x: integer\nuse({ x = 1 })")
  -- Each variable of a declaration is its own.
  refuses("local a, b: integer, integer\na = 1\nuse(a)\nuse(b)", "b")
  accepts("local a, b: integer, integer\na, b = 1, 2\nuse(a)\nuse(b)")
  -- The value is read before the targets are written.
  refuses("local x: integer\nx, use = x, use", "x")
  accepts("local x: integer\nx, use = 1, use\nuse(x)")
end

--- A type that admits nil is nil until assigned, and a local with a value
--- is never refused.
local function test_a_local_whose_type_admits_nil_or_that_has_a_value_is_accepted()
  accepts("local x: integer | nil\nuse(x)")
  accepts("local x: any\nuse(x)")
  accepts("local x: integer = 1\nuse(x)")
  accepts("local x = 1\nuse(x)")
  accepts("local a, b: integer, integer = 1, 2\nuse(a)\nuse(b)")
  -- A call may give the rest of the values.
  accepts("local function two(): integer, integer return 1, 2 end\n" ..
      "local a, b: integer, integer = two()\nuse(a)\nuse(b)")
  -- An alias of a union with nil admits it.
  accepts("local type Maybe = integer | nil\nlocal x: Maybe\nuse(x)")
  -- A type variable might be any type, so it is not taken to admit nil.
  local source = head .. "local function g<T>(_: T)\n  local x: T\n  use(x)\nend\nuse(g)\n"
  local errors = type_errors(source)
  assert(#errors == 1 and errors[1].code == "not_assigned" and errors[1].variable == "x", shown(errors))
end

--- A variable with neither a type nor a value is the other refusal.
local function test_a_local_with_neither_a_type_nor_a_value_is_told_its_type()
  local source = program("local x\nx = 1\nuse(x)")
  local errors = type_errors(source)
  assert(#errors >= 1 and errors[1].code == "no_type" and errors[1].variable == "x", shown(errors))
  assert(errors[1].msg == "variable 'x' has no type or initial value", errors[1].msg)
  assert(teal.replacement(errors[1], source) ==
      "'x' has neither a type nor a value: declare `local x: T | nil` for one that starts with no value, " ..
      "or give it a value where it is declared")
end

--- An `if` skips the assignment unless every branch makes it or ends.
local function test_an_if_assigns_only_if_every_path_through_it_does()
  accepts("local x: integer\nif cond() then x = 1 else x = 2 end\nuse(x)")
  accepts("local x: integer\nif cond() then x = 1 elseif cond() then x = 2 else x = 3 end\nuse(x)")
  local without = refuses("local x: integer\nif cond() then x = 1 end\nuse(x)", "x")
  assert(without.skipped_kind == "if" and without.skipped_y == 6 and without.skipped_x == 1,
    tostring(without.skipped_kind) .. " " .. tostring(without.skipped_y))
  assert(hint(without, "local x: integer\nif cond() then x = 1 end\nuse(x)") ==
      read_msg .. " (the `if` at 6:1 has no `else` that assigns it)" .. rewrite)
  local branch = refuses("local x: integer\nif cond() then x = 1 elseif cond() then x = 2 else use(1) end\nuse(x)", "x")
  assert(branch.skipped_kind == "branch" and branch.skipped_y == 6, tostring(branch.skipped_kind))
  assert(hint(branch, "local x: integer\nif cond() then x = 1 elseif cond() then x = 2 else use(1) end\nuse(x)") ==
      read_msg .. " (the branch at 6:" .. tostring(branch.skipped_x) .. " does not assign it)" .. rewrite)
  -- The branch that skips comes before the one that assigns, and between two.
  refuses("local x: integer\nif cond() then use(1) else x = 1 end\nuse(x)", "x")
  refuses("local x: integer\nif cond() then x = 1 elseif cond() then use(1) else x = 2 end\nuse(x)", "x")
  refuses("local x: integer\nif cond() then use(1) elseif cond() then x = 1 else x = 2 end\nuse(x)", "x")
  accepts("local x: integer\nif cond() then use(1) x = 1 else x = 2 end\nuse(x)")
  -- A condition is read where it stands.
  refuses("local x: integer\nif x == 1 then x = 1 end", "x")
  accepts("local x: integer\nx = 1\nif x == 1 then use(1) end")
  -- Assigned before, or in a block that holds both.
  accepts("local x: integer\ndo\n  x = 1\nend\nuse(x)")
  accepts("local x: integer\nif cond() then\n  x = 1\n  if cond() then use(x) end\nend")
  refuses("local x: integer\nif cond() then\n  if cond() then x = 1 end\n  use(x)\nend", "x")
end

--- A branch that ends does not reach the read.
local function test_a_branch_that_ends_does_not_reach_the_read()
  accepts("local x: integer\nif cond() then x = 1 else return end\nuse(x)")
  accepts("local x: integer\nif cond() then x = 1 else stop() end\nuse(x)")
  accepts("local x: integer\nif cond() then x = 1 elseif cond() then error(\"no\") else return end\nuse(x)")
  accepts("local x: integer\nif not cond() then return end\nx = 1\nuse(x)")
  -- A return that leaves the read behind it nothing to read.
  accepts("local x: integer\nif cond() then return end\nx = 1\nuse(x)")
  -- A call of a function that may return does not end the path.
  refuses("local x: integer\nif cond() then x = 1 else use(2) end\nuse(x)", "x")
  refuses("local x: integer\nif cond() then x = 1 else use(1) end\nif cond() then return end\nuse(x)", "x")
end

--- A loop body may run no time.
local function test_a_loop_assigns_only_if_it_always_runs()
  local while_loop = refuses("local x: integer\nwhile cond() do x = 1 end\nuse(x)", "x")
  assert(while_loop.skipped_kind == "loop" and while_loop.skipped_y == 6, tostring(while_loop.skipped_kind))
  assert(hint(while_loop, "local x: integer\nwhile cond() do x = 1 end\nuse(x)") ==
      read_msg .. " (the loop at 6:1 may run no pass)" .. rewrite)
  refuses("local x: integer\nfor i = 1, 3 do x = i end\nuse(x)", "x")
  refuses("local x: integer\nfor _, i in ipairs({ 1 }) do x = i end\nuse(x)", "x")
  -- A loop that always runs once assigns, and a `break` before the
  -- assignment leaves it unassigned.
  accepts("local x: integer\nrepeat x = 1 until cond()\nuse(x)")
  accepts("local x: integer\nwhile true do x = 1 break end\nuse(x)")
  accepts("local x: integer\nwhile true do\n  if cond() then x = 1 break end\nend\nuse(x)")
  refuses("local x: integer\nwhile true do\n  if cond() then break end\n  x = 1\nend\nuse(x)", "x")
  refuses("local x: integer\nrepeat\n  if cond() then break end\n  x = 1\nuntil cond()\nuse(x)", "x")
  -- Where every `break` has assigned, the loop has.
  accepts("local x: integer\nwhile true do\n  x = 1\n  if cond() then break end\nend\nuse(x)")
  -- A read in the loop is a read at the state of the loop's start.
  refuses("local x: integer\nwhile cond() do\n  use(x)\n  x = 1\nend", "x")
  accepts("local x: integer\nx = 0\nwhile cond() do\n  use(x)\n  x = 1\nend")
  -- The condition after a repeat body sees what the body assigned.
  accepts("local x: integer\nrepeat x = 1 until x == 1")
  refuses("local x: integer\nrepeat\n  if cond() then x = 1 end\nuntil x == 1", "x")
  -- A loop that cannot end leaves nothing after it to read.
  accepts("local x: integer\nwhile true do use(1) end\nuse(x)")
  -- A loop that stops by a `break` of a loop inside it is not left by it.
  accepts("local x: integer\nwhile true do\n  for _ = 1, 2 do break end\n  x = 1\n  break\nend\nuse(x)")
end

--- A `goto` takes the state it leaves with to its label.
local function test_a_goto_brings_the_state_it_left_with_to_its_label()
  refuses("local x: integer\ngoto skip\nx = 1\n::skip::\nuse(x)", "x")
  accepts("local x: integer\nx = 1\ngoto skip\nuse(1)\n::skip::\nuse(x)")
  -- The usual continue.
  accepts("local x: integer\nfor i = 1, 3 do\n  if cond() then goto continue end\n  x = i\n  use(x)\n  ::continue::\nend")
  refuses("local x: integer\nfor i = 1, 3 do\n  if cond() then goto continue end\n  x = i\n  ::continue::\n  use(x)\nend", "x")
  -- Out of a loop to a label after it.
  refuses("local x: integer\nwhile true do\n  if cond() then goto out end\n  x = 1\nend\n::out::\nuse(x)", "x")
  accepts("local x: integer\nwhile true do\n  x = 1\n  if cond() then goto out end\nend\n::out::\nuse(x)")
  -- A label reached by a goto alone has its state, and one reached by both has the meeting.
  accepts("local x: integer\nif cond() then x = 1 goto out end\nx = 2\n::out::\nuse(x)")
  refuses("local x: integer\nif cond() then goto out end\nx = 2\n::out::\nuse(x)", "x")
  -- A goto back to a label before the read adds nothing to the label.
  refuses("local x: integer\n::again::\nif cond() then x = 1 end\nif not cond() then goto again end\nuse(x)", "x")
  accepts("local x: integer\n::again::\nx = 1\nif cond() then goto again end\nuse(x)")
end

--- A function literal that names the local reads it where it is made.
local function test_a_function_that_names_a_local_reads_it_where_it_is_made()
  local made = refuses("local x: integer\nlocal g = function() use(x) end\nuse(g)", "x")
  assert(made.closure == true and made.msg == read_msg .. ": the function made here names it", made.msg)
  assert(hint(made, "local x: integer\nlocal g = function() use(x) end\nuse(g)") ==
      read_msg .. " (creating a function reads every variable it names, and an assignment inside one does " ..
      "not count outside it)" .. rewrite)
  -- An assignment in a function is not one for the code around it.
  refuses("local x: integer\nlocal function set() x = 1 end\nset()\nuse(x)", "x")
  refuses("local x: integer\nuse(function() x = 1 end)\nuse(x)", "x")
  refuses("local x: integer\nlocal ok = pcall(function() x = 1 end)\nuse(ok)", "x")
  -- Made after the assignment, it reads an assigned variable.
  accepts("local x: integer\nx = 1\nlocal function g() use(x) end\ng()")
  accepts("local x: integer\nif cond() then x = 1 else x = 2 end\nuse(function() use(x) end)")
  -- A named function, a method and a nested function are all made.
  refuses("local x: integer\nlocal function g() local function h() use(x) end h() end\ng()", "x")
  refuses("local x: integer\nlocal t = { run = function() use(x) end }\nuse(t)", "x")
  -- A function a parameter or a local of its own hides the name from does not name it.
  accepts("local x: integer\nlocal function g(x: integer) use(x) end\ng(1)")
  accepts("local x: integer\nlocal g = function() local x = 1 use(x) end\ng()")
  accepts("local x: integer\nlocal g = function() for x = 1, 2 do use(x) end end\ng()")
  -- A forward declaration the function that calls it names is made first, the
  -- plan's rule: assign it, or write the function where it is used.
  refuses("local g: function(integer)\nlocal function h(n: integer) g(n) end\ng = h\nh(1)", "g")
  accepts("local function h(n: integer) use(n) end\nlocal g: function(integer) = h\nlocal function k(n: integer) g(n) end\nk(1)")
end

--- A local of the same name hides the variable from its scope.
local function test_a_local_of_the_same_name_hides_the_variable()
  accepts("local x: integer\ndo\n  local x = 1\n  use(x)\nend\nx = 2\nuse(x)")
  refuses("local x: integer\ndo\n  local x = 1\n  use(x)\nend\nuse(x)", "x")
  accepts("local x: integer\nfor x = 1, 2 do use(x) end\nx = 3\nuse(x)")
  accepts("local x: integer\nfor _, x in ipairs({ 1 }) do use(x) end\nx = 3\nuse(x)")
  accepts("local x: integer\nrepeat\n  local x = 2\n  use(x)\nuntil x == 2\nx = 1\nuse(x)")
  -- The value of a declaration that hides it is the variable's own.
  refuses("local x: integer\nlocal x: integer = x\nuse(x)", "x")
  -- What is assigned under the hiding is not the variable's.
  refuses("local x: integer\ndo\n  local x = 1\n  x = 2\nend\nuse(x)", "x")
  -- A `break` after the hiding still ends the loop with the state before it.
  refuses("local x: integer\nwhile true do\n  local x = 1\n  use(x)\n  break\nend\nuse(x)", "x")
end

--- A pass over a program of many variables follows each by itself.
local function test_each_variable_is_followed_by_itself()
  local errors = type_errors(program("local a: integer\nlocal b: integer\na = 1\nuse(a)\nuse(b)\nb = 2"))
  assert(#errors == 1 and errors[1].variable == "b", shown(errors))
  errors = type_errors(program("local a: integer\nlocal b: integer\nuse(a)\nuse(b)"))
  assert(#errors == 2 and errors[1].variable == "a" and errors[2].variable == "b", shown(errors))
end
