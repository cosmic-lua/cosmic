--- An entry point's signature ([`lang.check`]'s `entry_signature`): what a program's `cmd/<name>/main.tl`, or a file
--- run on its own, returns is called with the command line's words, `{string}`, and what that call returns is read as
--- the exit code, so a function that wants other parameters, or returns no exit code, is refused where it is
--- returned, not when it runs. [`lang.check_programs`] marks `cmd.<name>.main` and `lone` as entry points.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{}

--- The codes of what `source`, as the module `module`, is refused for, space separated: "" for none.
local function codes(source: string, module: string): string
  return Programs.codes(Programs.runner()(source, module))
end

--- The message and the fix of the first error of `source` as `module`.
local function first(source: string, module: string): string
  local r = Programs.runner()(source, module)
  local e = assert(r.errors[1], "no error in\n" .. source)
  return e.msg .. "\n" .. e.fix
end

--- A record `M` whose `main` is of type `main`, and a value of it with `body` as that main.
local function record_of(main: string, body: string): string
  return "local record M\n  main: " .. main .. "\nend\nlocal m: M = { main = " .. body .. " }\nreturn m\n"
end

local function test_a_function_that_wants_an_integer_is_refused()
  local source = "return function(n: integer): integer\n  return n\nend\n"
  assert(codes(source, "cmd.tool.main") == "entry_signature", codes(source, "cmd.tool.main"))
  assert(codes(source, "lone") == "entry_signature")
  local said = first(source, "lone")
  assert(said:find("`function(integer): integer`", 1, true) ~= nil, said)
  assert(said:find("`{string}`", 1, true) ~= nil, said)
end

local function test_a_rest_of_strings_or_a_second_word_is_refused()
  assert(codes("return function(...: string): integer\n  print(...)\n  return 0\nend\n", "lone") == "entry_signature")
  assert(codes("return function(argv: {string}, more: string): integer\n  return #argv + #more\nend\n", "lone") ==
      "entry_signature")
end

local function test_what_takes_the_words_is_taken()
  for _, params in ipairs({ "argv: {string}", "", "argv?: {string}", "argv: mut {string}", "argv: {integer: string}",
      "argv: {any}", "argv: any", "...: any", "argv: {string}, more?: string" }) do
    local source = "return function(" .. params .. "): integer\n  return 0\nend\n"
    assert(codes(source, "cmd.tool.main") == "", params .. ": " .. codes(source, "cmd.tool.main"))
  end
  assert(codes("local function main(argv: {string})\n  print(#argv)\nend\nreturn main\n", "lone") == "")
end

local function test_what_it_returns_is_held_as_an_exit_code()
  local source = "return function(argv: {string}): boolean\n  return #argv > 0\nend\n"
  assert(codes(source, "lone") == "entry_signature")
  assert(first(source, "lone"):find("exit code", 1, true) ~= nil)
  local values: {string: string} = { ["integer"] = "0", ["string"] = "\"0\"", ["integer?"] = "nil", ["number"] = "0" }
  for rets, value in pairs(values) do
    local fine = "return function(argv: {string}): " .. rets .. "\n  return " .. value .. "\nend\n"
    assert(codes(fine, "lone") == "", rets .. ": " .. codes(fine, "lone"))
  end
end

local function test_a_file_run_alone_is_held_by_its_record_main()
  local wrong = record_of("function(integer): integer", "function(n: integer): integer return n end")
  assert(codes(wrong, "lone") == "entry_signature", codes(wrong, "lone"))
  assert(first(wrong, "lone"):find("`main` of the record", 1, true) ~= nil)
  assert(codes(record_of("function({string}): integer", "function(argv: {string}): integer return #argv end"), "lone") == "")
  local optional = "local record M\n  main?: function(integer): integer\nend\nlocal m: M = {}\nreturn m\n"
  assert(codes(optional, "lone") == "entry_signature", codes(optional, "lone"))
  assert(codes("local record M\n  size: integer\nend\nlocal m: M = { size = 1 }\nreturn m\n", "lone") == "")
end

local function test_a_generic_record_main_is_read_with_its_arguments()
  local source = "local record R<T>\n  main: function(T): integer\nend\n" ..
    "local r: R<{string}> = { main = function(argv: {string}): integer return #argv end }\nreturn r\n"
  assert(codes(source, "lone") == "", codes(source, "lone"))
  local wrong = "local record R<T>\n  main: function(T): integer\nend\n" ..
    "local r: R<integer> = { main = function(n: integer): integer return n end }\nreturn r\n"
  assert(codes(wrong, "lone") == "entry_signature", codes(wrong, "lone"))
end

local function test_an_optional_function_is_held_as_the_function()
  local source = "local function pick(): (function(integer): integer)?\n  return nil\nend\n" ..
    "local f: (function(integer): integer)? = pick()\nreturn f\n"
  assert(codes(source, "lone") == "entry_signature", codes(source, "lone"))
end

--- A built program calls its main module, which must be a function: a record, or a function that may be nil, is refused.
local function test_a_program_main_must_be_a_function()
  local right = record_of("function({string}): integer", "function(argv: {string}): integer return #argv end")
  assert(codes(right, "cmd.tool.main") == "entry_signature", codes(right, "cmd.tool.main"))
  assert(first(right, "cmd.tool.main"):find("no function", 1, true) ~= nil)
end

--- A module that is no entry point may return any function.
local function test_a_library_may_return_any_function()
  assert(codes("local function f(n: integer): integer\n  return n\nend\nreturn f\n", "cmd.tool.helper") == "")
  assert(codes("local function f(n: integer): integer\n  return n\nend\nreturn f\n", "tools.lone") == "")
end
