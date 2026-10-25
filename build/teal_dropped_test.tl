--- A use refused because the narrowing it relied on was dropped, or was never
--- made: the checker's error says which place, what dropped it and where, and
--- [`build.teal`]'s hint says the copy to a local that keeps the check with
--- the use. A local's narrowing is dropped by an assignment; a field or a
--- global is narrowed by no test, whatever code runs between the test and the
--- use, and its refusal says to copy it to a local.
local type compiler = require("build.compiler")
local teal = require("build.teal")

--- The type errors the checker reports for `source`.
local function type_errors(source: string): {compiler.Error}
  local built = assert(teal.load(true))
  local _, result = built.gen(source, nil, nil, "tl")
  return assert(result).type_errors
end

--- Holds the checker to reporting `msg` for `source`, and
--- [`teal.replacement`] to answering it `want`.
local function answers(source: string, msg: string, want: string)
  local seen: mut {string} = {}
  for _, e in ipairs(type_errors(source)) do
    if e.msg == msg then
      local got = teal.replacement(e, source)
      -- A note follows the error's own hint, after a semicolon.
      assert(got == want or (got ~= nil and got:sub(-#want - 2) == "; " .. want), tostring(got))
      return
    end
    seen[#seen + 1] = e.msg
  end
  error("no '" .. msg .. "' among: " .. table.concat(seen, "; "))
end

--- The first error of kind `code` for `source`.
local function diagnostic(source: string, code: compiler.ErrorCode): compiler.Error
  local seen: mut {string} = {}
  for _, e in ipairs(type_errors(source)) do
    local e_code = e.code
    if e_code == code then
      return e
    end
    seen[#seen + 1] = tostring(e_code) .. " " .. e.msg
  end
  error("no " .. code .. " among: " .. table.concat(seen, "; ") .. "\n" .. source)
end

--- The first error for `source` that carries the note that a test of a field
--- or a global narrowed nothing.
local function noted(source: string): compiler.Error
  local seen: mut {string} = {}
  for _, e in ipairs(type_errors(source)) do
    if e.also == "narrowing_not_local" then
      return e
    end
    seen[#seen + 1] = tostring(e.code) .. " " .. e.msg
  end
  error("no note among: " .. table.concat(seen, "; ") .. "\n" .. source)
end

--- Whether `found` holds the strings `want`, in order.
local function listed(found: {string}?, ...: string): boolean
  local want = { ... }
  if found == nil or #found ~= #want then
    return false
  end
  for i, member in ipairs(want) do
    if found[i] ~= member then
      return false
    end
  end
  return true
end

local head <const> = "local record R\n  n: integer | nil\nend\nlocal r: R = { n = 1 }\n" ..
  "local function clear()\n  r.n = nil\nend\n"
local plus <const> = "cannot use operator '+' for types integer | nil and integer"

--- What a test of the field `place` at `at` is told: only a local is narrowed,
--- and the copy of the field in `name` is.
local function field_hint(place: string, at: string, name: string): string
  return "note: the test of '" .. place .. "' at " .. at .. " does not narrow it, as a field is not narrowed " ..
    "by a test: only a local is. If this use relies on that test, copy it first (`local " .. name .. " = " ..
    place .. "`), then test and use `" .. name .. "`. If a loop or later code updates '" .. place ..
    "', update `" .. name .. "` instead and store it back after (`" .. place .. " = " .. name .. "`)"
end

--- A test of a field is told the copy, wherever code that runs comes between
--- the test and the use: a call, a write through an alias, an operator, a
--- loop, a function.
local function test_a_test_of_a_field_is_told_the_copy_wherever_code_runs()
  answers(head .. "if r.n then\n  print(r.n + 1)\nend\n", plus, field_hint("r.n", "8:5", "n"))
  answers(head .. "if r.n then\n  clear()\n  print(r.n + 1)\nend\n", plus, field_hint("r.n", "8:5", "n"))
  answers(head .. "if r.n then\n  local c = r\n  c.n = nil\n  print(r.n + 1)\nend\n", plus,
    field_hint("r.n", "8:5", "n"))
  -- A write through a longer path.
  answers("local record Box\n  n: integer | nil\nend\nlocal record Holder\n  box: Box\nend\n" ..
      "local b: Box = { n = 1 }\nlocal h: Holder = { box = b }\n" ..
      "if b.n then\n  h.box.n = nil\n  print(b.n + 1)\nend\n", plus, field_hint("b.n", "9:5", "n"))
  -- An operator that runs a metamethod.
  answers("local record V\n  metamethod __add: function(V, V): V\nend\n" ..
      "local record H\n  n: integer | nil\nend\nlocal v: V = setmetatable({} as V, {})\nlocal h: H = { n = 1 }\n" ..
      "if h.n then\n  local sum = v + v\n  print(h.n + 1, sum)\nend\n", plus, field_hint("h.n", "9:5", "n"))
  -- A loop whose later passes run what its first reads.
  answers(head .. "if r.n then\n  for _ = 1, 2 do\n    print(r.n + 1)\n    clear()\n  end\nend\n", plus,
    field_hint("r.n", "8:5", "n"))
  -- A function literal.
  answers(head .. "if r.n then\n  local get = function(): integer\n    return r.n + 1\n  end\n  print(get())\nend\n",
    plus, field_hint("r.n", "8:5", "n"))
  -- A place assigned after the test.
  answers(head .. "if r.n then\n  r.n = nil\n  print(r.n + 1)\nend\n", plus,
    "'r.n' was checked, then assigned at 9:3: the checker narrows nothing after an assignment, " ..
      "so keep the value in a local (`local n = <the value>`, r.n = n) and use that")
  -- A binding of the name is another place: the test of the outer `r.n` says
  -- nothing of the new one, and the use is refused without the note.
  local rebound = head .. "local r2: R = { n = 2 }\nif r.n then\n  local r = r2\n  print(r.n + 1)\nend\n"
  local refused = 0
  for _, e in ipairs(type_errors(rebound)) do
    if e.msg == plus then
      refused = refused + 1
      assert(e.also == nil and e.code == "operator_binary", tostring(e.also) .. " " .. tostring(e.code))
    end
  end
  assert(refused == 1, "the use of the new binding's field is refused once")
  -- A copy of the same value keeps the note.
  answers(head .. "if r.n then\n  local r = r\n  print(r.n + 1)\nend\n", plus, field_hint("r.n", "8:5", "n"))
  -- Wherever the value is used.
  answers(head .. "local function use(n: integer) print(n) end\nif r.n then\n  clear()\n  use(r.n)\nend\n",
    "argument 1: got integer | nil, expected integer", field_hint("r.n", "9:5", "n"))
  -- The end of a block that holds a `<close>` local.
  local closing <const> = "local record C\n  n: integer | nil\n  metamethod __close: function(C)\nend\n" ..
    "local c0: C = setmetatable({ n = 1 } as C, {})\n"
  answers(closing .. "if c0.n then\n  do\n    local c <close> = c0\n    local _ = c\n  end\n  print(c0.n + 1)\nend\n", plus,
    field_hint("c0.n", "6:6", "n"))
  -- Copied to a local first, the program is accepted whatever runs between.
  local copied = head .. "local n = r.n\nif n then\n  clear()\n  print(n + 1)\nend\n"
  assert(#type_errors(copied) == 0, copied)
end

--- The copy is named for a name that is free where the test is: not a local
--- or a global the program has, nor a builtin or a keyword. The field's own
--- name is the first choice; then the place with its dot made an underscore.
local function test_the_copy_is_named_for_a_name_that_is_free()
  local record_head <const> = "local record R\n  a: integer | nil\n  type: integer | nil\n  next: integer | nil\n" ..
    "  g: integer | nil\nend\nlocal r: R = { a = 1 }\n"
  -- A local of that name.
  answers(record_head .. "local a = 5\nif r.a then\n  print(r.a + a)\nend\n", plus,
    field_hint("r.a", "9:5", "r_a"))
  -- The names of builtins.
  answers(record_head .. "if r.type then\n  print(r.type + 1)\nend\n", plus, field_hint("r.type", "8:5", "r_type"))
  answers(record_head .. "if r.next then\n  print(r.next + 1)\nend\n", plus, field_hint("r.next", "8:5", "r_next"))
  -- A global of the program.
  answers("global g: string = \"g\"\n" .. record_head .. "if r.g then\n  print(r.g + 1)\nend\n", plus,
    field_hint("r.g", "9:5", "r_g"))
  -- Free: the field's own name.
  answers(record_head .. "if r.a then\n  print(r.a + 1)\nend\n", plus, field_hint("r.a", "8:5", "a"))
  -- Both taken: the flat name is, too.
  answers(record_head .. "local a = 5\nlocal r_a = 6\nif r.a then\n  print(r.a + a + r_a)\nend\n", plus,
    field_hint("r.a", "10:5", "r_a_copy"))
end

--- The name is also not one the enclosing function declares after the test,
--- and not one that begins with an underscore.
local function test_the_copy_is_not_named_for_a_later_declaration_or_an_underscore()
  local record_head <const> = "local record R\n  a: integer | nil\n  _x: integer | nil\nend\nlocal r: R = { a = 1 }\n"
  -- A local declared in the arm that uses the copy.
  answers(record_head .. "if r.a then\n  local a = 5\n  print(r.a + a)\nend\n", plus, field_hint("r.a", "6:5", "r_a"))
  -- A local function, a parameter of a function literal and a loop variable.
  answers(record_head .. "if r.a then\n  print(r.a + 1)\nend\nlocal function a() end\nprint(a)\n", plus,
    field_hint("r.a", "6:5", "r_a"))
  answers(record_head .. "local function f(a: integer)\n  if r.a then\n    print(r.a + a)\n  end\nend\nprint(f)\n", plus,
    field_hint("r.a", "7:7", "r_a"))
  answers(record_head .. "if r.a then\n  print(r.a + 1)\nend\nfor a = 1, 2 do print(a) end\n", plus,
    field_hint("r.a", "6:5", "r_a"))
  -- Declared in another function: not the enclosing one, so free.
  answers(record_head .. "local function g()\n  local a = 1\n  return a\nend\nlocal function f()\n" ..
      "  if r.a then\n    print(r.a + 1)\n  end\nend\nprint(f, g)\n", plus, field_hint("r.a", "11:7", "a"))
  -- An underscore name.
  answers(record_head .. "if r._x then\n  print(r._x + 1)\nend\n", plus, field_hint("r._x", "6:5", "r__x"))
end

--- A field `is` cannot test is told the copy to a local, the way a test that
--- narrows nothing is.
local function test_an_is_of_a_field_is_told_the_copy()
  local source <const> = "local record R\n  v: string | number\nend\nlocal r: R = { v = 1 }\n" ..
    "if r.v is string then\n  print(1)\nend\n"
  answers(source, "can only use 'is' on variables",
    "note: `is` tests a local, not a field. Copy 'r.v' to a local first (`local v = r.v`), then test and use `v`")
  local at = noted(source)
  assert(at.dropped_place == "r.v" and at.dropped_kind == "field", tostring(at.dropped_place))
  -- Copied to a local, it is accepted.
  assert(#type_errors((source:gsub("if r.v is string", "local v = r.v\nif v is string"))) == 0)
end

--- A field a loop counts down is told to be copied before the loop, the local
--- counted, and the field stored back after.
local function test_a_field_a_loop_updates_is_told_to_update_the_copy()
  answers(head .. "while r.n and r.n > 0 do\n  r.n = r.n - 1\nend\n",
    "cannot use operator '>' for types integer | nil and integer", field_hint("r.n", "8:8", "n"))
end

--- A test of a global is told the copy to a local, which no function assigns.
local function test_a_test_of_a_global_is_told_the_copy()
  local source = "global gx: integer | nil = 1\nlocal function reset()\n  gx = nil\nend\n" ..
    "if gx then\n  reset()\n  print(gx + 1)\nend\n"
  -- The copy is named for a name that nothing else has: the global's own is taken.
  answers(source, plus,
    "note: the test of 'gx' at 5:4 does not narrow it, as a global is not narrowed by a test: only a local " ..
      "is. If this use relies on that test, copy it first (`local gx_copy = gx`), then test and use `gx_copy`. " ..
      "If a loop or later code updates 'gx', update `gx_copy` instead and store it back after (`gx = gx_copy`)")
  -- A global assigned a union value is not narrowed by the assignment.
  answers("global gu: string | number\nlocal function f(): string\n  gu = \"x\"\n  return gu\nend\nprint(f)\n",
    "in return value: got string | number, expected string",
    "note: the assignment to 'gu' at 3:3 does not narrow it, as a global is not narrowed by an assignment: " ..
      "only a local is. If this use relies on that assignment, keep the value in a local " ..
      "(`local gu_copy = <the value>`, gu = gu_copy) and use that")
  local copied = "global gx: integer | nil = 1\nlocal function reset()\n  gx = nil\nend\n" ..
    "local copy = gx\nif copy then\n  reset()\n  print(copy + 1)\nend\n"
  assert(#type_errors(copied) == 0, copied)
end

--- A local assigned after its test, or before a function that reads it runs, is
--- told the copy that no assignment changes.
local function test_a_narrowing_dropped_by_an_assignment_or_a_function_is_told_the_copy()
  local local_head <const> = "local function maybe(): integer | nil return nil end\nlocal n: integer | nil = maybe()\n"
  answers(local_head .. "if n then\n  n = maybe()\n  print(n + 1)\nend\n", plus,
    "'n' was checked, then assigned at 4:3: the checker narrows nothing after an assignment, " ..
      "so keep the value in a local (`local n = <the value>`, n = n) and use that")
  answers(local_head .. "if n then\n  local get = function(): integer\n    return n + 1\n  end\n  n = maybe()\n  print(get())\nend\n",
    plus,
    "'n' was checked, but the function at 4:15 runs later, when it may have changed: " ..
      "copy it to a local before the function (`local n = n`), check and use that")
end

--- The refusal says which place, what kind it is or what dropped it, and
--- where, beside what the use was refused for.
local function test_a_refusal_of_an_unnarrowed_or_dropped_place_carries_the_place_and_the_cause()
  local called = noted(head .. "if r.n then\n  clear()\n  print(r.n + 1)\nend\n")
  assert(called.code == "operator_binary", tostring(called.code))
  assert(called.dropped_place == "r.n" and called.dropped_kind == "field" and
      called.dropped_by == "r.n" and called.dropped_y == 8 and called.dropped_x == 5,
    tostring(called.dropped_place) .. " " .. tostring(called.dropped_kind) .. " " .. tostring(called.dropped_by))
  assert(called.y == 10 and called.x == 13 and listed(called.left_members, "integer", "nil"), called.msg)
  -- A refusal keeps its own fields.
  local argument = noted(head .. "local function use(n: integer) print(n) end\n" ..
      "if r.n then\n  clear()\n  use(r.n)\nend\n")
  assert(argument.context == "argument" and argument.index == 1 and listed(argument.got_members, "integer", "nil"),
    argument.msg)
  local indexed = noted("local record Inner\n  v: integer\nend\nlocal record O\n  inner: Inner | nil\nend\n" ..
      "local o: O = {}\nif o.inner then\n  print(o.inner.v)\nend\n")
  assert(indexed.dropped_place == "o.inner" and listed(indexed.members, "Inner", "nil"), indexed.msg)
  local used = noted("global gx: integer | nil = 1\nif gx then\n  print(gx + 1)\nend\n")
  assert(used.dropped_place == "gx" and used.dropped_kind == "global" and used.dropped_by == "gx",
    tostring(used.dropped_kind))
  -- A local dropped by an assignment, in a loop.
  local assigned = diagnostic("local function maybe(): integer | nil return nil end\nlocal n: integer | nil = maybe()\nif n then\n  n = maybe()\n  print(n + 1)\nend\n", "narrowing_dropped")
  assert(assigned.dropped_place == "n" and assigned.dropped_kind == "assignment" and
      assigned.dropped_by == "n = ..." and assigned.dropped_y == 4, tostring(assigned.dropped_by))
  -- An operand that was never narrowed is refused for what it is.
  local plain = diagnostic(head .. "print(r.n + 1)\n", "operator_binary")
  assert(plain.dropped_place == nil and plain.dropped_kind == nil)
end

--- A read in a loop that assigns the place later in it is told so: the check
--- before the loop does not hold in a later pass, and the copy goes at the top
--- of the loop body.
local function test_a_read_before_a_later_assignment_in_the_loop_is_told_the_loop()
  local source = "local function id(v: integer | nil): integer | nil\n  return v\nend\n" ..
    "local function g(x: integer | nil): integer\n  local sink = 0\n  if x then\n    local i = 0\n" ..
    "    while i < 2 do\n      sink = sink + x + 1\n      x = id(nil)\n      i = i + 1\n    end\n  end\n" ..
    "  return sink\nend\nreturn g\n"
  answers(source, "cannot use operator '+' for types integer and integer | nil",
    "'x' was checked, but the loop assigns it at 10:7, after this use, so a later pass reaches the use with " ..
      "what it assigned: copy it to a local at the top of the loop body (`local x = x`), then check and use that")
end

--- The assignment a loop names is to the place's own binding: a local of the
--- same name declared in the loop, or in a function literal in it, is another.
local function test_the_loop_names_an_assignment_to_the_place_itself()
  local source = "local function id(v: integer | nil): integer | nil\n  return v\nend\n" ..
    "local function g(x: integer | nil): integer\n  local s = 0\n  if x then\n    for _ = 1, 2 do\n" ..
    "      s = s + x\n      x = id(nil)\n      local x = 5\n      x = 6\n      s = s + x\n    end\n  end\n" ..
    "  return s\nend\nreturn g\n"
  local e = diagnostic(source, "narrowing_dropped")
  assert(e.dropped_y == 9 and e.dropped_x == 7, tostring(e.dropped_y) .. ":" .. tostring(e.dropped_x))
  -- With only the other binding assigned, nothing assigns the place.
  local other = "local function g(x: integer | nil): integer\n  local s = 0\n  if x then\n    for _ = 1, 2 do\n" ..
    "      s = s + x\n      local x = 5\n      x = 6\n      s = s + x\n    end\n  end\n  return s\nend\nreturn g\n"
  assert(#type_errors(other) == 0, other)
end

--- A test inside a function narrows a local of the code around it only if
--- nothing assigns it after the function is made: the function may run, in a
--- coroutine that yields between the test and the use, when it has changed.
local function test_a_captured_local_the_code_around_assigns_is_not_narrowed()
  local opening <const> = "local function maybe(): integer | nil\n  return nil\nend\nlocal function f(): function\n" ..
    "  local x: integer | nil = maybe()\n"
  local refused = opening .. "  local co = coroutine.wrap(function()\n    if x then\n      coroutine.yield()\n" ..
    "      print(x + 1)\n    end\n  end)\n  x = nil\n  return co\nend\nreturn f\n"
  answers(refused, "cannot use operator '+' for types integer | nil and integer",
    "note: the test of 'x' at 7:8 does not narrow it in this function: the code around the function assigns 'x' " ..
      "after the function is made, and the function may run when it has changed (in a coroutine, or later). If this " ..
      "use relies on that test, copy it first (`local x_copy = x`) inside the function, then test and use `x_copy`")
  assert(noted(refused).dropped_kind == "captured")
  -- Copied inside the function, the program is accepted.
  local copied = opening .. "  local co = coroutine.wrap(function()\n    local v = x\n    if v then\n" ..
    "      coroutine.yield()\n      print(v + 1)\n    end\n  end)\n  x = nil\n  return co\nend\nreturn f\n"
  assert(#type_errors(copied) == 0, copied)
  -- Nothing assigns it after the function is made: the test narrows.
  local fixed = opening .. "  local co = coroutine.wrap(function()\n    if x then\n      coroutine.yield()\n" ..
    "      print(x + 1)\n    end\n  end)\n  return co\nend\nreturn f\n"
  assert(#type_errors(fixed) == 0, fixed)
end
