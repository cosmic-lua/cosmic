--- A use refused because the narrowing it relied on was dropped: the
--- checker's error says which place, what dropped it and where, and
--- [`build.teal`]'s hint says the copy to a local that keeps the check
--- with the use. The refused programs here are accepted by a checker that
--- drops nothing, and fail at run time.
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
  local seen: {string} = {}
  for _, e in ipairs(type_errors(source)) do
    if e.msg == msg then
      local got = teal.replacement(e, source)
      assert(got == want, tostring(got))
      return
    end
    seen[#seen + 1] = e.msg
  end
  error("no '" .. msg .. "' among: " .. table.concat(seen, "; "))
end

--- The first error of kind `code` for `source`.
local function diagnostic(source: string, code: compiler.ErrorCode): compiler.Error
  local seen: {string} = {}
  for _, e in ipairs(type_errors(source)) do
    if e.code == code then
      return e
    end
    seen[#seen + 1] = tostring(e.code) .. " " .. e.msg
  end
  error("no " .. code .. " among: " .. table.concat(seen, "; ") .. "\n" .. source)
end

--- Whether `found` holds the strings `want`, in order.
local function listed(found: {string} | nil, ...: string): boolean
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

--- The call and the write of the two programs a checker that drops
--- nothing accepts.
local function test_a_narrowing_dropped_by_a_call_or_an_alias_write_is_told_the_copy()
  answers(head .. "if r.n then\n  clear()\n  print(r.n + 1)\nend\n", plus,
    "'r.n' was checked, but the call `clear(...)` at 9:3 may change it: " ..
      "copy it to a local before the call (`local n = r.n`), check and use that")
  answers(head .. "if r.n then\n  local c = r\n  c.n = nil\n  print(r.n + 1)\nend\n", plus,
    "'r.n' was checked, but the write `c.n = ...` at 10:3 may be to the same table: " ..
      "copy it to a local before the write (`local n = r.n`), check and use that")
  -- A write through a longer path names its last field.
  answers("local record Box\n  n: integer | nil\nend\nlocal record Holder\n  box: Box\nend\n" ..
      "local b: Box = { n = 1 }\nlocal h: Holder = { box = b }\n" ..
      "if b.n then\n  h.box.n = nil\n  print(b.n + 1)\nend\n", plus,
    "'b.n' was checked, but the write `h.box.n = ...` at 10:3 may be to the same table: " ..
      "copy it to a local before the write (`local n = b.n`), check and use that")
  -- Copied to a local first, the program is accepted.
  local copied = head .. "local n = r.n\nif n then\n  clear()\n  print(n + 1)\nend\n"
  assert(#type_errors(copied) == 0, copied)
end

--- The other things that run code, and a local a function literal assigns.
local function test_a_narrowing_dropped_by_other_code_is_told_what_ran_it()
  -- An operator that runs a metamethod.
  answers("local record V\n  metamethod __add: function(V, V): V\nend\n" ..
      "local record H\n  n: integer | nil\nend\nlocal v: V = setmetatable({} as V, {})\nlocal h: H = { n = 1 }\n" ..
      "if h.n then\n  local sum = v + v\n  print(h.n + 1, sum)\nend\n", plus,
    "'h.n' was checked, but the operator `+` at 10:15 may run a metamethod that changes it: " ..
      "copy it to a local before the operator (`local n = h.n`), check and use that")
  -- A loop whose later passes run what its first reads.
  answers(head .. "if r.n then\n  for _ = 1, 2 do\n    print(r.n + 1)\n    clear()\n  end\nend\n",
    "'r.n' was narrowed before this loop, but the loop's previous pass ran clear(...) at 11:5, " ..
      "which may have changed it",
    "'r.n' was checked, but the call `clear(...)` at 11:5 in this loop may change it before the loop " ..
      "comes round again: copy it to a local before the loop (`local n = r.n`), check and use that")
  -- A local a function literal assigns is copied into one nothing assigns.
  answers("local x: integer | nil = 1\nlocal function reset()\n  x = nil\nend\n" ..
      "if x then\n  reset()\n  print(x + 1)\nend\n", plus,
    "'x' was checked, but the call `reset(...)` at 6:3 may change it: copy it into a local of its own " ..
      "after the check (`local x = x`, which no function assigns)")
  -- A place assigned after the check.
  answers(head .. "if r.n then\n  r.n = nil\n  print(r.n + 1)\nend\n", plus,
    "'r.n' was checked, then assigned at 9:3: the checker narrows nothing after an assignment, " ..
      "so keep the value in a local (`local n = <the value>`, r.n = n) and use that")
  -- Wherever the value is used.
  answers(head .. "local function use(n: integer) print(n) end\nif r.n then\n  clear()\n  use(r.n)\nend\n",
    "argument 1: got integer | nil, expected integer",
    "'r.n' was checked, but the call `clear(...)` at 10:3 may change it: " ..
      "copy it to a local before the call (`local n = r.n`), check and use that")
end

--- The refusal says which place, what dropped it, and where, beside what
--- the use was refused for.
local function test_a_refusal_of_a_dropped_narrowing_carries_the_place_and_what_dropped_it()
  local called = diagnostic(head .. "if r.n then\n  clear()\n  print(r.n + 1)\nend\n", "narrowing_dropped")
  assert(called.dropped_place == "r.n" and called.dropped_kind == "call" and
      called.dropped_by == "clear(...)" and called.dropped_y == 9 and called.dropped_x == 3,
    tostring(called.dropped_place) .. " " .. tostring(called.dropped_kind) .. " " .. tostring(called.dropped_by))
  assert(called.y == 10 and called.x == 13 and listed(called.left_members, "integer", "nil"), called.msg)
  local written = diagnostic(head .. "if r.n then\n  local c = r\n  c.n = nil\n  print(r.n + 1)\nend\n",
    "narrowing_dropped")
  assert(written.dropped_kind == "write" and written.dropped_by == "c.n = ..." and written.dropped_y == 10,
    tostring(written.dropped_by))
  -- A refusal keeps its own fields.
  local argument = diagnostic(head .. "local function use(n: integer) print(n) end\n" ..
      "if r.n then\n  clear()\n  use(r.n)\nend\n", "narrowing_dropped")
  assert(argument.context == "argument" and argument.index == 1 and listed(argument.got_members, "integer", "nil"),
    argument.msg)
  local indexed = diagnostic("local record Inner\n  v: integer\nend\nlocal record O\n  inner: Inner | nil\nend\n" ..
      "local o: O = {}\nlocal function clear()\n  o.inner = nil\nend\n" ..
      "if o.inner then\n  clear()\n  print(o.inner.v)\nend\n", "narrowing_dropped")
  assert(indexed.dropped_place == "o.inner" and listed(indexed.members, "Inner", "nil"), indexed.msg)
  local looped = diagnostic("local function more(): boolean return false end\n" .. head ..
      "if r.n then\n  while true do\n    print(r.n + 1)\n    if more() then break end\n  end\nend\n", "narrowing_dropped")
  assert(looped.dropped_kind == "loop" and looped.dropped_by == "more(...)" and looped.dropped_place == "r.n",
    tostring(looped.dropped_by))
  -- The condition of a loop is run before the body, in every pass.
  local conditioned = diagnostic("local function more(): boolean return false end\n" .. head ..
      "if r.n then\n  while more() do\n    print(r.n + 1)\n  end\nend\n", "narrowing_dropped")
  assert(conditioned.dropped_kind == "call" and conditioned.dropped_by == "more(...)", tostring(conditioned.dropped_kind))
  -- An operand that was never narrowed is refused for what it is.
  local plain = diagnostic(head .. "print(r.n + 1)\n", "operator_binary")
  assert(plain.dropped_place == nil and plain.dropped_kind == nil)
end
