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
  { expression = "io.open", message = got("function(string, ? OpenMode): (FILE | nil, string | nil, integer | nil)") },
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

local golden <const> = [=====[
FILE => got FILE, expected boolean
FILE.SeekWhence => cannot use a type definition as a concrete value
FILE.SetVBufMode => cannot use a type definition as a concrete value
FILE.close => got function(FILE): (boolean | nil, string | nil, integer | nil), expected boolean
FILE.flush => got function(FILE): (boolean | nil, string | nil, integer | nil), expected boolean
FILE.lines => cannot match against any alternatives of the polymorphic type
FILE.read => cannot match against any alternatives of the polymorphic type
FILE.seek => got function(FILE, ? SeekWhence, ? integer): (integer | nil, string | nil, integer | nil), expected boolean
FILE.setvbuf => got function(FILE, SetVBufMode, ? integer): (boolean | nil, string | nil, integer | nil), expected boolean
FILE.write => got function(FILE, ...: string | number): (FILE | nil, string | nil, integer | nil), expected boolean
_VERSION => got string, expected boolean
any => got any, expected boolean
arg => got {string}, expected boolean
assert => got function(A | nil, ? B, ...: <any type>): (A, B, <any type>...), expected boolean
collectgarbage => cannot match against any alternatives of the polymorphic type
coroutine => got coroutine, expected boolean
coroutine.Function => cannot use a type definition as a concrete value
coroutine.close => got function(thread): (boolean, string), expected boolean
coroutine.create => got function(Function): thread, expected boolean
coroutine.isyieldable => got function(): boolean, expected boolean
coroutine.resume => got function(thread, ...: <any type>): (boolean, <any type>...), expected boolean
coroutine.running => got function(): (thread, boolean), expected boolean
coroutine.status => got function(thread): string, expected boolean
coroutine.wrap => got function(Function): function(...: <any type>): <any type>..., expected boolean
coroutine.yield => got function(...: <any type>): <any type>..., expected boolean
debug => got debug, expected boolean
debug.AnyFunction => cannot use a type definition as a concrete value
debug.GetInfoTable => got record GetInfoTable, expected boolean
debug.HookEvent => cannot use a type definition as a concrete value
debug.HookFunction => cannot use a type definition as a concrete value
debug.debug => got function(), expected boolean
debug.gethook => got function(? thread): (HookFunction | nil, integer), expected boolean
debug.getinfo => cannot match against any alternatives of the polymorphic type
debug.getlocal => cannot match against any alternatives of the polymorphic type
debug.getmetatable => got function(T): metatable<T> | nil, expected boolean
debug.getregistry => got function(): {<any type> : <any type>}, expected boolean
debug.getupvalue => got function(AnyFunction, integer): (string | nil, <any type>), expected boolean
debug.getuservalue => got function(userdata, ? integer): (<any type>, boolean), expected boolean
debug.sethook => cannot match against any alternatives of the polymorphic type
debug.setlocal => cannot match against any alternatives of the polymorphic type
debug.setmetatable => got function(T, metatable<T>): T, expected boolean
debug.setupvalue => got function(AnyFunction, integer, <any type>): string | nil, expected boolean
debug.setuservalue => got function(U, <any type>, integer): U, expected boolean
debug.traceback => cannot match against any alternatives of the polymorphic type
debug.upvalueid => got function(AnyFunction, integer): userdata, expected boolean
debug.upvaluejoin => got function(AnyFunction, integer, AnyFunction, integer), expected boolean
dofile => got function(? string): <any type>..., expected boolean
error => got function(? <any type>, ? integer): never, expected boolean
getmetatable => got function(T): metatable<T>, expected boolean
io => got io, expected boolean
io.FileType => cannot use a type definition as a concrete value
io.OpenMode => cannot use a type definition as a concrete value
io.close => got function(? FILE), expected boolean
io.flush => got function(), expected boolean
io.input => got function(? FILE | string): FILE, expected boolean
io.lines => cannot match against any alternatives of the polymorphic type
io.open => got function(string, ? OpenMode): (FILE | nil, string | nil, integer | nil), expected boolean
io.output => got function(? FILE | string): FILE, expected boolean
io.popen => got function(string, ? OpenMode): (FILE | nil, string | nil, integer | nil), expected boolean
io.read => cannot match against any alternatives of the polymorphic type
io.stderr => got FILE, expected boolean
io.stdin => got FILE, expected boolean
io.stdout => got FILE, expected boolean
io.tmpfile => got function(): (FILE | nil, string | nil, integer | nil), expected boolean
io.type => got function(<any type>): FileType | nil, expected boolean
io.write => got function(...: string | number): (FILE | nil, string | nil, integer | nil), expected boolean
ipairs => got function({A}): (function({A}, integer): (integer, A), {A}, integer), expected boolean
load => cannot match against any alternatives of the polymorphic type
loadfile => cannot match against any alternatives of the polymorphic type
math => got math, expected boolean
math.Numeric => cannot use a type definition as a concrete value
math.abs => got function(N): N, expected boolean
math.acos => got function(number): number, expected boolean
math.asin => got function(number): number, expected boolean
math.atan => got function(number, ? number): number, expected boolean
math.atan2 => got function(number, number): number, expected boolean
math.ceil => got function(number): integer, expected boolean
math.cos => got function(number): number, expected boolean
math.cosh => got function(number): number, expected boolean
math.deg => got function(number): number, expected boolean
math.exp => got function(number): number, expected boolean
math.floor => got function(number): integer, expected boolean
math.fmod => cannot match against any alternatives of the polymorphic type
math.frexp => got function(number): (number, integer), expected boolean
math.huge => got number, expected boolean
math.ldexp => got function(number, integer): number, expected boolean
math.log => got function(number, ? number): number, expected boolean
math.log10 => got function(number): number, expected boolean
math.max => cannot match against any alternatives of the polymorphic type
math.maxinteger => got integer, expected boolean
math.min => cannot match against any alternatives of the polymorphic type
math.mininteger => got integer, expected boolean
math.modf => got function(number): (integer, number), expected boolean
math.pi => got number, expected boolean
math.pow => got function(number, number): number, expected boolean
math.rad => got function(number): number, expected boolean
math.random => cannot match against any alternatives of the polymorphic type
math.randomseed => got function(? integer, ? integer): (integer, integer), expected boolean
math.sin => got function(number): number, expected boolean
math.sinh => got function(number): number, expected boolean
math.sqrt => got function(number): number, expected boolean
math.tan => got function(number): number, expected boolean
math.tanh => got function(number): number, expected boolean
math.tointeger => got function(<any type>): integer, expected boolean
math.type => got function(<any type>): string | nil, expected boolean
math.ult => got function(number, number): boolean, expected boolean
metatable => got metatable<T>, expected boolean
next => cannot match against any alternatives of the polymorphic type
os => got os, expected boolean
os.DateMode => cannot use a type definition as a concrete value
os.DateTable => got record DateTable, expected boolean
os.clock => got function(): number, expected boolean
os.date => cannot match against any alternatives of the polymorphic type
os.difftime => got function(integer, integer): number, expected boolean
os.execute => got function(string): (boolean | nil, string, integer), expected boolean
os.exit => got function(? integer | boolean, ? boolean), expected boolean
os.getenv => got function(string): string | nil, expected boolean
os.remove => got function(string): (boolean | nil, string | nil, integer | nil), expected boolean
os.rename => got function(string, string): (boolean | nil, string | nil, integer | nil), expected boolean
os.setlocale => got function(string, ? string): string | nil, expected boolean
os.time => got function(? DateTable): integer, expected boolean
os.tmpname => got function(): string, expected boolean
package => got package, expected boolean
package.config => got string, expected boolean
package.cpath => got string, expected boolean
package.loaded => got {string : <any type>}, expected boolean
package.loaders => got {function(string): (function(? string, ? <any type>): <any type>, <any type>)}, expected boolean
package.loadlib => got function(string, string): (function(...: <any type>): <any type>... | nil, string | nil, string | nil), expected boolean
package.path => got string, expected boolean
package.preload => got {string : function(? string, ? <any type>): <any type>}, expected boolean
package.searchers => got {function(string): (function(? string, ? <any type>): <any type>, <any type>)}, expected boolean
package.searchpath => got function(string, string, ? string, ? string): (string | nil, string | nil), expected boolean
pairs => got function({K : V}): (function({K : V}, ? K): (K, V), {K : V}, K), expected boolean
pcall => got function(function(...: <any type>): <any type>..., ...: <any type>): (boolean, <any type>...), expected boolean
print => got function(...: <any type>), expected boolean
rawequal => got function(<any type>, <any type>): boolean, expected boolean
rawget => cannot match against any alternatives of the polymorphic type
rawlen => got function({A}): integer, expected boolean
rawset => got function({K : V}, K, V): {K : V}, expected boolean
require => got function(string): <any type>, expected boolean
select => cannot match against any alternatives of the polymorphic type
setmetatable => got function(T, metatable<T>): T, expected boolean
string => got string, expected boolean
string.byte => cannot match against any alternatives of the polymorphic type
string.char => got function(...: integer): string, expected boolean
string.dump => got function(function(...: <any type>): <any type>, ? boolean): string, expected boolean
string.find => got function(string, string, ? integer, ? boolean): (integer, integer, string...), expected boolean
string.format => got function(string, ...: <any type>): string, expected boolean
string.gmatch => got function(string, string, ? integer): function(): string..., expected boolean
string.gsub => cannot match against any alternatives of the polymorphic type
string.len => got function(string): integer, expected boolean
string.lower => got function(string): string, expected boolean
string.match => got function(string, string, ? integer): string..., expected boolean
string.pack => got function(string, ...: <any type>): string, expected boolean
string.packsize => got function(string): integer, expected boolean
string.rep => got function(string, integer, ? string): string, expected boolean
string.reverse => got function(string): string, expected boolean
string.sub => got function(string, integer, ? integer): string, expected boolean
string.unpack => got function(string, string, ? integer): <any type>..., expected boolean
string.upper => got function(string): string, expected boolean
table => got table, expected boolean
table.PackTable => got record PackTable, expected boolean
table.SortFunction => cannot use a type definition as a concrete value
table.concat => got function({string | number}, ? string, ? integer, ? integer): string, expected boolean
table.insert => cannot match against any alternatives of the polymorphic type
table.move => got function({A}, integer, integer, integer, ? {A}): {A}, expected boolean
table.pack => cannot match against any alternatives of the polymorphic type
table.remove => got function({A}, ? integer): A, expected boolean
table.sort => got function({A}, ? SortFunction<A>), expected boolean
table.unpack => cannot match against any alternatives of the polymorphic type
thread => got thread, expected boolean
tonumber => cannot match against any alternatives of the polymorphic type
tostring => got function(<any type>): string, expected boolean
type => got function(<any type>): string, expected boolean
userdata => got userdata, expected boolean
utf8 => got utf8, expected boolean
utf8.char => got function(...: number): string, expected boolean
utf8.charpattern => got string, expected boolean
utf8.codepoint => got function(string, ? number, ? number, ? boolean): integer..., expected boolean
utf8.codes => got function(string, ? boolean): (function(string, ? integer): (integer, integer), string, integer), expected boolean
utf8.len => got function(string, ? number, ? number, ? boolean): (integer | nil, integer), expected boolean
utf8.offset => got function(string, number, ? number): integer | nil, expected boolean
xpcall => got function(function(...: <any type>): <any type>..., XpcallMsghFunction, ...: <any type>): (boolean, <any type>...), expected boolean
]=====]

--- What the checker says of `expression` where a boolean is declared,
--- without the message's fixed lead.
local function printed(built: compiler, expression: string): string
  local message = said(built, expression)
  if message:sub(1, #in_declaration) == in_declaration then
    return message:sub(#in_declaration + 1)
  end
  return message
end

--- Every global and every field of a global record, as the checker prints
--- it, one `name => type` line each in name order.
local function dump(built: compiler): string
  local env = assert(built.new_env({}))
  local globals = env.globals as {string:{any:any}}
  local names: {string} = {}
  for name in pairs(globals) do
    if name:sub(1, 1) ~= "@" and name ~= "..." then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  local lines: {string} = {}
  for _, name in ipairs(names) do
    lines[#lines + 1] = name .. " => " .. printed(built, name)
    local declared = globals[name]["t"] as {any:any}
    local definition = declared and declared["def"] as {any:any}
    local fields = definition and definition["fields"] as {string:any}
    if fields then
      local keys: {string} = {}
      for key in pairs(fields) do
        keys[#keys + 1] = key
      end
      table.sort(keys)
      for _, key in ipairs(keys) do
        lines[#lines + 1] = name .. "." .. key .. " => " .. printed(built, name .. "." .. key)
      end
    end
  end
  return table.concat(lines, "\n")
end

--- Any change to a standard library declaration shows here, so it is
--- seen in review. When one is made on purpose, replace `golden` above
--- with the actual list this failure prints between its markers.
local function test_every_standard_library_declaration_is_pinned()
  local actual = dump((assert(teal.load(true))))
  local expected = (golden:gsub("\n$", ""))
  assert(actual == expected,
    "a standard library declaration prints differently than pinned; if " ..
      "that is intended, replace `golden` with:\n----\n" .. actual .. "\n----")
end
