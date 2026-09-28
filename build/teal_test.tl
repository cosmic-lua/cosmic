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

--- An accumulator declared `local peak = 0` is told it was inferred an
--- integer, from which line, and the two spellings that hold a number.
local function test_an_integer_inferred_accumulator_names_the_fix()
  local source = "local n = 1\nlocal peak = 0\nfor _ = 1, n do\n  peak = peak + 1.5\nend\n"
  assert(teal.replacement(integer_msg, source, 4, 15) ==
    "peak is an integer, inferred from 'local peak = 0' at line 2; " ..
    "write 'local peak = 0.0' or 'local peak: number = 0' to hold a number")
end

--- A declaration that already says its type, or is not one plain
--- integer literal, or a field, is given no hint; nor is another message.
local function test_an_integer_hint_never_misleads()
  assert(teal.replacement(integer_msg, "local x: integer = 0\nx = x / 2\n", 2, 7) == nil)
  assert(teal.replacement(integer_msg, "local x = #arg\nx = x / 2\n", 2, 7) == nil)
  assert(teal.replacement(integer_msg, "local x, y = 0, 1\nx = x / 2\n", 2, 7) == nil)
  assert(teal.replacement(integer_msg, "local t = {n = 0}\nt.n = t.n + 0.5\n", 2, 9) == nil)
  assert(teal.replacement("in assignment: got string, expected integer",
    "local x = 0\nx = 'a'\n", 2, 5) == nil)
end
