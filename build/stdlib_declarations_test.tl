--- The Lua standard library's declarations, [`checker/stdlib.d.tl`], keep
--- the types they were declared with. Moving them out of the checker, or
--- editing the file, must not change what the checker makes of a standard
--- library name, so each name below is pinned as the checker prints it: a
--- value of that type where a boolean is declared is refused with the type
--- in the message, and a call that its alternatives resolve answers the
--- type it returns.
local type compiler = require("build.compiler")
local teal = require("build.teal")

local record Pin
  expression: string
  message: string
end

local in_declaration <const> = "in local declaration: probe: "

--- What the checker says of `expression` where a boolean is declared:
--- every type error, joined.
local function said(built: compiler, expression: string): string
  local _, result = built.gen("local probe: boolean = " .. expression .. "\n", nil, nil, "tl")
  local messages: {string} = {}
  for _, e in ipairs(result.type_errors) do
    messages[#messages + 1] = e.msg
  end
  return table.concat(messages, " | ")
end

local function got(declared: string): string
  return in_declaration .. "got " .. declared .. ", expected boolean"
end

--- Names that are one function type, as the checker prints it.
local functions: {Pin} = {
  { expression = "string.match", message = got("function(string, string, ? integer): string...") },
  { expression = "string.find",
    message = got("function(string, string, ? integer, ? boolean): (integer, integer, string...)") },
  { expression = "string.format", message = got("function(string, ...: <any type>): string") },
  { expression = "string.unpack",
    message = got("function(string, string, ? integer): <any type>...") },
  { expression = "table.remove", message = got("function({A}, ? integer): A") },
  { expression = "rawset", message = got("function({K : V}, K, V): {K : V}") },
  { expression = "pcall",
    message = got("function(function(...: <any type>): <any type>..., ...: <any type>): (boolean, <any type>...)") },
  { expression = "setmetatable", message = got("function(T, metatable<T>): T") },
  { expression = "getmetatable", message = got("function(T): metatable<T>") },
  { expression = "assert", message = got("function(A | nil, ? B, ...: <any type>): (A, B, <any type>...)") },
  { expression = "error", message = got("function(? <any type>, ? integer): never") },
  { expression = "type", message = got("function(<any type>): string") },
  { expression = "tostring", message = got("function(<any type>): string") },
  { expression = "require", message = got("function(string): <any type>") },
  { expression = "ipairs",
    message = got("function({A}): (function({A}, integer): (integer, A), {A}, integer)") },
  { expression = "pairs",
    message = got("function({K : V}): (function({K : V}, ? K): (K, V), {K : V}, K)") },
  { expression = "io.open", message = got("function(string, ? OpenMode): (FILE, string, integer)") },
  { expression = "os.time", message = got("function(? DateTable): integer") },
  { expression = "math.tointeger", message = got("function(<any type>): integer") },
  { expression = "coroutine.resume",
    message = got("function(thread, ...: <any type>): (boolean, <any type>...)") },
  { expression = "coroutine.wrap",
    message = got("function(Function): function(...: <any type>): <any type>...") },
}

--- Names declared as several alternatives, which the checker does not
--- print as one type: a call that picks an alternative answers its
--- return, or is refused by it.
local alternatives: {Pin} = {
  { expression = 'select(2, "a", "b")', message = 'argument 2: got string "a", expected boolean' },
  { expression = 'select("#", 1)', message = 'argument 1: got string "#", expected integer' },
  { expression = 'rawget({ a = 1 }, "a")', message = got("integer") },
  { expression = 'string.gsub("a", "b", "c")', message = got("string") },
  { expression = "table.unpack({ 1 })",
    message = "argument 1: tuple entry 1 of type A1 does not match type of array elements, which is integer" },
  { expression = 'load("x")', message = got("function(...: <any type>): <any type>...") },
  { expression = 'string.rep("a", 2)', message = got("string") },
}

local function holds(pins: {Pin})
  local built = assert(teal.load(true))
  for _, pin in ipairs(pins) do
    local message = said(built, pin.expression)
    assert(message == pin.message, pin.expression .. ": the checker says\n  " ..
        message .. "\nnot\n  " .. pin.message)
  end
end

local function test_a_standard_library_function_keeps_its_declared_type()
  holds(functions)
end

local function test_a_standard_library_alternative_keeps_its_declared_type()
  holds(alternatives)
end
