--- Regression tests for `build.teal.lazy`: the capsule that loads the
--- compiler on first use has to behave as the compiler itself,
--- including for writes. tl reaches `search_module` and `path` through
--- its own module table, so an override `serve` writes has to land on
--- the loaded compiler rather than on the capsule; a capsule that kept
--- the write for itself would leave the checker searching the
--- filesystem.
local teal = require("build.teal")

--- A field written through the capsule reaches the loaded compiler:
--- the capsule itself never holds it, and reading it back through the
--- capsule finds the written value, not the compiler's own.
local function test_lazy_write_lands_on_the_compiler()
  local built = teal.lazy()
  local marker = function(_name: string, _search_all: boolean): string | nil, any
    return nil
  end
  built.search_module = marker
  built.path = "lazy-test"
  assert(rawget(built as {any:any}, "search_module") == nil,
    "the capsule kept the write instead of passing it on")
  assert(rawget(built as {any:any}, "path") == nil)
  assert(built.search_module == marker)
  assert(built.path == "lazy-test")
end

--- A read through the capsule answers from the loaded compiler.
local function test_lazy_read_answers_from_the_compiler()
  local built = teal.lazy()
  assert(type(built.new_env) == "function")
  assert(type(built.gen) == "function")
end

--- Two capsules load two compilers: a write through one is not seen
--- through the other, the same as two `teal.load` calls.
local function test_lazy_capsules_are_independent()
  local first = teal.lazy()
  local second = teal.lazy()
  first.path = "first"
  second.path = "second"
  assert(first.path == "first")
  assert(second.path == "second")
end

local integer_msg = "in assignment: got number, expected integer"

--- What `teal.replacement` says for the first "got number, expected
--- integer" the checker reports for `source`, and where: nil when it
--- reports none, or the hint is nil.
local function hint_for(source: string): string | nil, string
  local built = assert(teal.load())
  local _, result = built.gen(source, nil, nil, "tl")
  for _, e in ipairs(result ~= nil and result.type_errors or {}) do
    if e.msg == integer_msg then
      return teal.replacement(e.msg, source, e.y, e.x), e.y .. ":" .. e.x
    end
  end
  return nil, "no such error"
end

local function said(name: string, line: integer, literal: string): string
  return name .. " is an integer, inferred from 'local " .. name .. " = " .. literal ..
    "' at line " .. line .. "; write 'local " .. name .. " = " .. literal ..
    ".0' or 'local " .. name .. ": number = " .. literal .. "' to hold a number"
end

--- An accumulator declared `local peak = 0` is told it was inferred an
--- integer, from which line, and the two spellings that hold a number.
local function test_an_integer_inferred_accumulator_names_the_fix()
  local source = "local n = 1\nlocal peak = 0\nfor _ = 1, n do\n  peak = peak + 1.5\nend\nprint(peak)\n"
  assert(hint_for(source) == said("peak", 2, "0"))
  assert(hint_for("local x = 0\nx = x / 2\nprint(x)\n") == said("x", 1, "0"))
  assert(hint_for("local x = 0\nx = 1.5\nprint(x)\n") == said("x", 1, "0"))
end

--- A trailing comment or semicolon on the declaration, an inner
--- function reading the outer local, and an `if` branch all resolve.
local function test_an_integer_hint_reads_the_declaration_through_the_parse()
  assert(hint_for("local x = 0 -- start\nx = x / 2\nprint(x)\n") == said("x", 1, "0"))
  assert(hint_for("local x = 0;\nx = x / 2\nprint(x)\n") == said("x", 1, "0"))
  assert(hint_for("local x = 0\nlocal function f()\n  if x then x = x / 2 end\nend\nf()\n")
    == said("x", 1, "0"))
end

--- The name is resolved, not searched for: a same-named local of a
--- closed function or block, or in a string or a comment, is not the
--- declaration, and a parameter or loop variable is not one either.
local function test_an_integer_hint_names_the_declaration_in_scope()
  local closed = "local function f()\n  local n = 0\n  return n\nend\n" ..
    "local function g(n: integer): integer\n  n = n / 2\n  return n\nend\nprint(f(), g(1))\n"
  assert(hint_for(closed) == nil)
  local looped = "local n = 0\nfor n = 1, 3 do\n  n = n / 2\nend\nprint(n)\n"
  assert(hint_for(looped) == nil)
  local block = "do\n  local n = 0\n  print(n)\nend\nlocal n: integer = 1\nn = n / 2\nprint(n)\n"
  assert(hint_for(block) == nil)
  local shadowed = "local n = 0\ndo\n  local n = 1\n  n = n / 2\n  print(n)\nend\nprint(n)\n"
  assert(hint_for(shadowed) == said("n", 3, "1"))
  local text = "local s = [[\nlocal q = 0\n]]\n-- local q = 0\nlocal q: integer = 1\nq = q / 2\nprint(s, q)\n"
  assert(hint_for(text) == nil)
end

--- No hint says a false thing: an annotated or uninitialized
--- declaration, a computed initializer, several names, a field, a
--- multiple assignment (and its neighbours), or a table's own
--- `name = ...` line.
local function test_an_integer_hint_never_misleads()
  assert(hint_for("local x: integer = 0\nx = x / 2\nprint(x)\n") == nil)
  assert(hint_for("local x: integer\nx = 1\nx = x / 2\nprint(x)\n") == nil)
  assert(hint_for("local x = #arg\nx = x / 2\nprint(x)\n") == nil)
  assert(hint_for("local x, y = 0, 1\nx = x / 2\nprint(x, y)\n") == nil)
  assert(hint_for("local t = {n = 0}\nt.n = t.n + 0.5\nprint(t)\n") == nil)
  assert(hint_for("local a, b = 0, 0\na, b = 1.5, 2\nprint(a, b)\n") == nil)
  assert(hint_for("local a = 0\nlocal b = 0\nprint(a)\nlocal a2 = 1.5; b = b + 0.5\nprint(b, a2)\n")
    == said("b", 2, "0"))
  assert(hint_for("local n = 0\nlocal t = {\n  n = 1,\n}\nn = n / 2\nprint(t, n)\n")
    == said("n", 1, "0"))
  assert(teal.replacement("in assignment: got string, expected integer",
    "local x = 0\nx = 'a'\n", 2, 5) == nil)
end
