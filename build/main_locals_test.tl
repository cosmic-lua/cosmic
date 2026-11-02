--- Tests of [`build.main_locals`]: the names of a `local` statement, a `local function`, and a record with functions
--- count, while a type, a record without functions, a literal `<const>` and a local in a body do not.
local MainLocals = require("build.main_locals")
local SyntaxNode = require("build.syntax_node")
local Test = require("cosmic.test")

Test.policy{}

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- The locals the main chunk of `text` holds.
local function held(text: string): integer
  return MainLocals.of_chunk((assert(SyntaxNode.parse(text, "t.tl"))))
end

local function test_every_name_and_function_counts()
  assert(held(source("local a, b = 1, 2", "local c", "local function d() end", "local e <close> = nil")) == 5)
end

local function test_a_literal_const_takes_no_register()
  assert(held(source("local N <const> = 6", "local S <const> = \"s\"", "local T <const> = { 1 }", "local u = 1")) == 2)
end

local function test_a_record_counts_only_with_functions_on_it()
  assert(held(source("local record Bare", "  x: integer", "end", "local record Table", "end",
    "function Table.f() end", "local enum Kind", "  \"a\"", "end", "local type Alias = Bare")) == 1)
end

local function test_a_local_in_a_body_is_not_the_main_chunks_own()
  assert(held(source("local function f()", "  local inner = 1", "  return inner", "end",
    "do", "  local scoped = 1", "end")) == 1)
end
