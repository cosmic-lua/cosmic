--- Checked, executable examples for Cosmic's Lua 5.5.1 runtime and Teal.
--- Search for a fully qualified API name or a language concept.
local record Example end

--- tonumber(value) parses decimal text; tonumber(text, base) accepts bases
--- 2..36. Runtime failure is nil, though Teal declares number/integer.
--- math.tointeger returns nil unless conversion is exact. tostring honors
--- __tostring and type returns a basic runtime type name.
function Example.conversion()
  local function positive_id(text: string): integer
    local n = tonumber(text)
    local id = math.tointeger(n)
    assert(id ~= nil and id > 0 and tostring(id) == text, "positive integer ID")
    return id
  end
  assert(positive_id("42") == 42 and tonumber("ff", 16) == 255)
  for _, bad in ipairs({ "1junk", "1.5", "0", "-1" }) do
    assert(not pcall(positive_id, bad))
  end
  assert(type(42) == "number")
end

--- assert(value, ...) raises with its second argument for false/nil and
--- otherwise returns all arguments. error(value, level) raises; level defaults
--- to 1 and zero adds no location. pcall(function, ...) returns success then
--- all results, including false/nil values, or false plus the error.
--- xpcall(function, handler, ...) transforms errors. print(...)
--- writes values. Runtime-only warn(message, ...) emits enabled warnings.
function Example.protected_calls()
  local ok, n = pcall(function(): integer return (assert(7)) end)
  assert(ok and n == 7)
  local false_ok, false_value = pcall(function(): boolean return false end)
  local all_args = assert(load(
    "local value,label=assert(7,'seven'); return value==7 and label=='seven'"))
  assert(all_args() and false_ok and false_value == false)
  local good = xpcall(function() error("broken", 0) end,
    function(reason: any): string return "handled: " .. tostring(reason) end)
  assert(not good)
end

--- ipairs(array) stops at its first nil. pairs(table) and next(table, key)
--- visit all keys in unspecified order. The length operator chooses a border
--- for tables with holes. select("#", ...) counts values; select(index, ...)
--- returns values from that positive or negative position.
function Example.iteration_select()
  local sum = 0
  for _, n in ipairs({ 2, 3, 5 }) do sum = sum + n end
  local seen: {string:boolean} = {}
  for key in pairs({ a = 1, b = 2 }) do seen[key] = true end
  local function tail(...: string): string, integer return select(2, ...), select("#", ...) end
  local value, count = tail("a", "b", "c")
  assert(sum == 10 and seen.a and seen.b and value == "b" and count == 3)
end

--- getmetatable and setmetatable query/install metatables; __metatable can
--- protect one. rawget, rawset, rawlen and rawequal bypass metamethods. Teal
--- does not infer arbitrary __index, __newindex, __call, arithmetic,
--- comparison, concatenation, length, or conversion metamethod behavior.
function Example.metatables_raw()
  local values: {string:integer} = { present = 2 }
  local mt: metatable<{string:integer}> = { __index = function(): integer return 9 end }
  setmetatable(values, mt)
  assert(values.missing == 9 and rawget(values, "missing") == nil)
  rawset(values, "missing", 4)
  assert(rawequal(values, values) and rawlen({ 1, 2 }) == 2 and getmetatable(values) == mt)
end

--- load(chunk, name, mode, environment) accepts text or a reader; runtime
--- failure is nil plus a syntax error. mode is "t", "b", or "bt". require
--- loads a checked dotted module key once and caches its returned value in
--- package.loaded; package.preload and package.searchers can provide loaders.
--- Unlike stock path-based Lua, package.path, package.cpath,
--- package.loadlib and package.searchpath are absent. package.config reports
--- the platform's path syntax but does not restore path-based loading. _G is the environment;
--- _VERSION identifies Lua. dofile/loadfile are removed: paths are not modules.
function Example.load_chunk()
  local environment: {any:any} = { answer = 40 }
  local chunk, trouble = load("return answer + 2", "example", "t", environment)
  assert(chunk ~= nil, trouble)
  assert(chunk() == 42)
end

--- Lua 5.5 collectgarbage supports "collect", "count", "stop", "restart",
--- "step", "isrunning", "generational", "incremental", and "param"; param
--- selects minormul, majorminor, minormajor, pause, stepmul, or stepsize.
--- Teal's older declaration types only the common commands, so use those in
--- checked code. Exact memory counts and timing are implementation details.
function Example.garbage_collection()
  assert(collectgarbage("count") >= 0 and type(collectgarbage("isrunning")) == "boolean")
end

--- table.concat(list, separator, i, j) joins an inclusive range (defaults
--- separator="", i=1, j=#list) and rejects non-string/non-number elements.
--- table.insert(list, [position,] value) defaults to appending and accepts
--- positions 1..#list+1; table.remove(list[, position]) defaults to #list,
--- shifts later elements, and returns the removed value. Positions 1..#list
--- remove an element; #list+1 is a permitted no-op returning nil. On an empty
--- list the default position is 0 and also returns nil; position 0 on a
--- nonempty list and positions outside those bounds raise.
--- table.move(a1, first, last, target[, a2]) defaults
--- a2 to a1, copies to target onward, returns a2, and safely handles overlap.
--- table.sort mutates with an optional strict
--- comparator. table.pack records argument count in n; table.unpack expands
--- i..j. Runtime-only table.create(nseq, nrec) allocates empty capacities; it
--- neither fills elements nor has a bundled Teal declaration.
function Example.table_operations()
  local xs = { "c", "a", "b" }
  local empty: {string} = {}
  assert(table.remove(empty) == nil and table.remove(xs, #xs + 1) == nil)
  assert(not pcall(function() table.remove(xs, 0) end))
  table.insert(xs, "z"); assert(table.remove(xs) == "z")
  table.insert(xs, 2, "x"); assert(table.remove(xs, 2) == "x")
  table.sort(xs); assert(table.concat(xs, ":", 1, 3) == "a:b:c")
  table.move(xs, 1, 2, 2, xs); assert(table.concat(xs) == "aab")
  local packed = table.pack("a", nil, "c"); assert(packed.n == 3)
  local a, b = table.unpack({ "a", "b" }); assert(a == "a" and b == "b")
end

--- string.byte/string.char convert bytes; string.len counts bytes; string.sub
--- requires i and uses inclusive byte indices (j defaults to -1). string.rep accepts an optional separator and
--- string.reverse reverses bytes. string.lower/string.upper use the runtime's
--- C locale and are not Unicode case conversion.
function Example.string_bytes()
  local a, b = string.byte("AB", 1, 2)
  assert(a == 65 and b == 66 and string.char(a, b) == "AB")
  assert(string.len("abc") == 3 and string.sub("cosmic", -3) == "mic")
  assert(string.rep("x", 3, ":") == "x:x:x" and string.reverse("ab") == "ba")
  assert(string.lower("ABC") == "abc" and string.upper("abc") == "ABC")
end

--- string.find(subject, pattern[, init[, plain]]) returns inclusive byte
--- positions followed by captures, or nil; init defaults to 1 and plain=true
--- disables patterns. string.match(subject, pattern[, init]) returns captures,
--- or the whole match when there are none. string.gmatch(subject, pattern[, init])
--- iterates non-overlapping matches. string.gsub(subject, pattern, replacement
--- [, limit]) returns changed text and replacement count; a string replacement
--- expands %0..%9 and %%, while table/function replacements keep the original
--- match when they return nil or false. Lua patterns use classes such as %a,
--- %d and bracket sets; captures use (), anchors are ^ and $, quantifiers are
--- *, +, -, and ?. %f[set] is a frontier and %bxy balances delimiters.
--- Malformed patterns and invalid capture references raise errors.
function Example.string_patterns()
  local first, last = string.find("name=cosmic", "(%a+)$")
  assert(first == 6 and last == 11 and string.find("a+b", "+", 1, true) == 2)
  assert(string.match("x=17", "(%d+)") == "17")
  assert(string.match("(a(b)c)", "%b()") == "(a(b)c)")
  assert(string.find("one word", "%f[%a]word%f[%A]") == 5)
  local changed, count = string.gsub("a1b2", "%d", "")
  assert(changed == "ab" and count == 2)
  local malformed = "(" .. ""
  assert(not pcall(string.match, "x", malformed))
end

--- string.format is printf-like. string.pack encodes binary values;
--- string.unpack returns decoded values and next byte position; string.packsize
--- requires a fixed-size format. string.dump produces a binary function chunk.
function Example.string_binary()
  assert(string.format("%04d", 7) == "0007")
  local data = string.pack(">I2", 513); assert(string.packsize(">I2") == 2)
  local n, next_position = string.unpack(">I2", data)
  assert(n == 513 and next_position == 3)
end

--- math.abs, math.floor, math.ceil, math.modf, math.fmod, math.min and math.max
--- cover ordinary numeric operations. math.tointeger returns nil unless exact;
--- math.type distinguishes "integer", "float", and non-numbers.
function Example.math_numeric()
  local whole, fraction = math.modf(2.25)
  assert(math.abs(-3) == 3 and math.floor(1.9) == 1 and math.ceil(1.1) == 2)
  assert(whole == 2 and fraction == .25 and math.fmod(-7, 3) == -1)
  assert(math.min(3, 1, 2) == 1 and math.max(3, 1, 2) == 3)
  assert(math.type(1) == "integer" and math.tointeger(1.5) == nil)
end

--- math.sin, math.cos, math.tan, math.asin, math.acos and math.atan(y[, x]) use
--- radians; math.rad/math.deg convert. math.sqrt, math.exp and math.log(x[, base]) operate
--- on floats. math.frexp/math.ldexp split/rebuild binary exponents. Constants
--- are math.pi, math.huge, math.maxinteger, math.mininteger; math.ult compares
--- unsigned integers. math.log defaults to the natural logarithm.
--- Compatibility math.atan2, math.cosh, math.sinh, math.tanh,
--- math.pow and math.log10 are declared by Teal but absent from this runtime.
--- math.random(), math.random(upper), and math.random(lower, upper) return a
--- float in [0,1), integers in inclusive ranges, or with upper=0 all bits of
--- a pseudo-random integer. Empty/reversed ranges raise. math.randomseed(x, y)
--- installs and returns a two-integer seed; sequences are implementation-specific.
function Example.math_functions()
  assert(math.sin(0) == 0 and math.cos(0) == 1 and math.tan(0) == 0)
  assert(math.sqrt(9) == 3 and math.exp(0) == 1 and math.log(8, 2) == 3)
  assert(math.deg(math.rad(180)) == 180 and math.pi > 3)
  local f, e = math.frexp(8); assert(math.ldexp(f, e) == 8)
end

--- utf8.char encodes code points and rejects values outside Unicode's range;
--- utf8.codepoint decodes an inclusive byte range. utf8.codes iterates byte
--- positions/code points. utf8.len returns count or nil plus an invalid byte
--- position. utf8.offset(subject, n[, i]) uses byte index i (default 1 for
--- nonnegative n and #subject+1 otherwise); n=0 finds the containing start.
--- Continuation-byte starts are invalid for nonzero n. Lua 5.5's optional lax
--- flag on utf8.len, utf8.codepoint, and utf8.codes accepts values beyond
--- Unicode's range while still requiring valid UTF-8 byte structure.
--- utf8.charpattern matches one UTF-8 sequence.
function Example.utf8_operations()
  local text = utf8.char(0x03bb, 0x61)
  assert(utf8.len(text) == 2 and utf8.codepoint(text) == 0x03bb)
  assert(utf8.offset(text, 1) == 1 and utf8.offset(text, 2) == 3)
  local count = 0; for _ in utf8.codes(text) do count = count + 1 end
  assert(count == 2 and string.match(text, utf8.charpattern) ~= nil)
end

--- coroutine.create makes a suspended thread; coroutine.resume returns success
--- then yielded/final values or an error. coroutine.yield suspends;
--- coroutine.status reports state; coroutine.running identifies current/main;
--- coroutine.isyieldable tests legality. coroutine.wrap raises resume errors;
--- coroutine.close accepts suspended or dead coroutines. It returns true when
--- no pending to-be-closed variable fails, or false plus that close error;
--- closing the running or a normal coroutine raises.
function Example.coroutines()
  local co = coroutine.create(function(): string coroutine.yield("paused"); return "done" end)
  assert(coroutine.status(co) == "suspended")
  local ok, state = coroutine.resume(co); assert(ok and state == "paused")
  ok, state = coroutine.resume(co); assert(ok and state == "done" and coroutine.status(co) == "dead")
  local abandoned = coroutine.create(function() coroutine.yield() end)
  assert(coroutine.close(abandoned))
end

--- Records are nominal table types; interfaces are structural requirements.
--- `record R is I` states conformance. Colon methods receive self; dot access
--- is an ordinary field/function access.
function Example.records_interfaces_methods()
  local interface Named
    name: string
  end
  local record User is Named
    name: string
    id: integer
    label: function(User): string
  end
  local user: User = {
    name = "Ada",
    id = 7,
    label = function(self: User): string return self.name .. ":" .. tostring(self.id) end,
  }
  local named: Named = user
  assert(named.name == "Ada" and user:label() == "Ada:7")
end

--- Enums are closed sets of literal strings. `{T}` is an array, `{K:V}` a map,
--- and `{A,B}` a fixed tuple.
function Example.enums_arrays_maps_tuples()
  local enum Color
    "red"
    "blue"
  end
  local color: Color = "red"; local array: {integer} = { 2, 3 }
  local map: {string:integer} = { answer = 42 }; local tuple: {string,integer} = { "age", 9 }
  assert(color == "red" and array[2] == 3 and map.answer == 42 and tuple[1] == "age")
end

--- A union `A | B` accepts only values assignable to one member; operations
--- must be valid for every member until control flow narrows it. Comparisons
--- with nil, `is` tests, and assert conditions narrow locals. `is` accepts a
--- variable, not an arbitrary expression. A union may contain only one table
--- type unless every table member is a record/interface declared with a
--- runtime discriminator using `where`. string|enum and unions of two enums
--- are rejected because their values are indistinguishable at runtime.
--- Narrowing tracks stable local bindings, not arbitrary mutable table fields.
--- `value as T` asks the checker to treat a value as T and adds no runtime check.
function Example.unions_narrowing_casts()
  local interface Named
    name: string
  end
  local record Left is Named
    where self.name == "left"
  end
  local record Right is Named
    where self.name == "right"
  end
  local function side(value: Left | Right): string
    if value is Left then return "L:" .. value.name end
    return "R:" .. value.name
  end
  local function render(value: string | integer | nil): string
    if value == nil then return "missing" end
    if value is integer then return tostring(value + 1) end
    return string.upper(value as string)
  end
  local maybe: string | nil = "present"
  assert(maybe ~= nil)
  local definitely: string = maybe
  local left: Left = { name = "left" }
  assert(side(left) == "L:left" and definitely == "present" and render(nil) == "missing" and
    render(1) == "2" and render("ok") == "OK")
end

--- A call must supply every required parameter with its declared type; a wrong
--- argument count or type reports the expected function signature. `name?: T`
--- marks an optional trailing position, and `...: T` accepts more T arguments.
--- Generics preserve input/output relationships; `<T is Constraint>` restricts
--- types. Multiple returns fill assignments
--- left-to-right, and only a final expression expands. Varargs use `...`.
function Example.generics_functions_returns()
  local interface HasName
    name: string
  end
  local function identity<T>(v: T): T return v end
  local function name_of<T is HasName>(v: T): string return v.name end
  local function quotient(a: integer, b: integer): integer, integer return a // b, a % b end
  local q, r = quotient(7, 3)
  assert(identity("x") == "x" and name_of({ name = "Ada" }) == "Ada" and q == 2 and r == 1)
end

--- Locals are lexical; `<const>` prevents reassignment and `<close>` invokes
--- __close at scope exit. if/while/repeat/for/break/goto follow Lua. Only false
--- and nil are falsey; and/or return operands. Operators include //, %, ^, ..,
--- #, shifts and bitwise operations with Lua precedence.
function Example.scoping_control_operators()
  local limit <const>: integer = 4; local total = 0
  for i = 1, limit do if i % 2 == 0 then total = total + i end end
  assert(total == 6 and (nil or "fallback") == "fallback" and #"abc" == 3)
end

--- A module returns its public value and callers use
--- `local Module = require("dotted.module")`. A `.d.tl` declaration describes
--- an external surface. Libraries often report failure as nil plus an error;
--- callers should inspect the documented convention.
function Example.modules_declarations_nil_error()
  local loaded = package.loaded["cosmic.removed_example"]
  assert(loaded == nil or type(loaded) == "table")
end

return Example
