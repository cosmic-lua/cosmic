--- The standard library's declarations as the new checker reads them ([`lang/stdlib.d.tl`] and [`lang/prelude.d.tl`]): a
--- function that answers nil where Lua does is declared so, a use of its result is held to that, and a callback of
--- `string.gsub` is typed by its arity. The fork's own reading is pinned by build/stdlib_declarations_test.tl.
local Fs = require("cosmic.fs")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{
  grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" },
    { path = "testdata/stdlib/globals.txt", letters = "r" } },
}

local function stdlib(): string
  return (assert(Fs.read("lang/stdlib.d.tl")))
end

local function prelude(): string
  return (assert(Fs.read("lang/prelude.d.tl")))
end

--- Checks `source` against the real standard library.
local function run(source: string): Programs.Run
  local r = Programs.standard(prelude(), stdlib(), source)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  return r
end

-- table.move ------------------------------------------------------------------------------------------------

local MOVE_HEAD <const> = "local xs: mut {integer} = {}\nlocal ys: mut {integer} = {}\nlocal n: integer = 3\n" ..
  "local record Box\n  mut items: mut {integer}\nend\nlocal box: Box = { items = {} }\n" ..
  "local function pick(): mut {integer}\n  return xs\nend\n"

--- Checks that `MOVE_HEAD` and `body` have the codes `want`.
local function moves(body: string, want: string)
  local got = Programs.codes(run(MOVE_HEAD .. body))
  assert(got == want, "got " .. got .. ", wanted " .. want .. " in " .. body)
end

local function test_a_move_of_elements_the_array_has_to_the_start_or_the_end_of_an_array_stands()
  -- the whole array, or its tail from a literal, to the start of another array or a table made for it
  moves("table.move(xs, 1, #xs, 1, ys)\n", "")
  moves("table.move(xs, 2, #xs, 1, {})\n", "")
  moves("local zs: mut {integer} = table.move(xs, 1, #xs - 1, 1, {})\n", "")
  -- onto the end of the array it continues, another array or the same one
  moves("table.move(xs, 1, #xs, #ys + 1, ys)\n", "")
  moves("table.move(xs, 1, #xs, #xs + 1)\n", "")
  -- down within one array, where the ranges overlap
  moves("table.move(xs, 2, #xs, 1)\n", "")
  -- fields of a name, and the table library through another name
  moves("table.move(box.items, 1, #box.items, #xs + 1, xs)\n", "")
  moves("local t = table\nt.move(xs, 1, #xs, 1, ys)\n", "")
end

local function test_a_move_that_may_copy_a_nil_or_leave_a_hole_is_refused()
  -- the range reaches past the end of the source
  moves("table.move(xs, 1, n, 1, ys)\n", "array_hole")
  moves("table.move(xs, 1, #xs + 1, 1, ys)\n", "array_hole")
  moves("table.move(xs, 1, #ys, 1, {})\n", "array_hole")
  moves("table.move(xs, 1, #xs - n, 1, {})\n", "array_hole")
  moves("table.move(xs, 1, 2, 1, {})\n", "array_hole")
  -- it starts below the first element, or where nothing says it does not
  moves("table.move(xs, 0, #xs, 1, {})\n", "array_hole")
  moves("table.move(xs, n, #xs, 1, {})\n", "array_hole")
  -- the destination is past the end of the array, or is not an index of one
  moves("table.move(xs, 1, #xs, 3, ys)\n", "array_hole")
  moves("table.move(xs, 1, #xs, #ys + 2, ys)\n", "array_hole")
  moves("table.move(xs, 1, #xs, #xs + 1, ys)\n", "array_hole")
  moves("table.move(xs, 1, #xs, n, ys)\n", "array_hole")
  moves("table.move(xs, 1, #xs, 0, ys)\n", "array_hole")
  moves("table.move(xs, 1, #xs, 2)\n", "array_hole")
  -- an argument that runs code may change a length after it is read
  moves("table.move(pick(), 1, #xs, 1, ys)\n", "array_hole")
  moves("table.move(xs, 1, #xs, 1, pick())\n", "array_hole")
  -- the function is read and called elsewhere, with arguments no one checks
  moves("local mv = table.move\nmv(xs, 1, n, 50, ys)\n", "overload_value array_hole")
  moves("local t = table\nt.move(xs, 1, n, 1, ys)\n", "array_hole")
  moves("(table.move)(xs, 1, #xs, 1, ys)\n", "overload_value array_hole")
  -- the member is the library's however it is spelled
  moves("table[\"move\"](xs, 1, n, 50)\n", "array_hole")
  moves("local mv = table[\"move\"]\nmv(xs, 1, n, 50)\n", "array_hole")
  moves("local mv = table[\"move\"]\nmv(xs, 1, #xs, 1, ys)\n", "array_hole arity")
  -- a table literal to start is dense only if it is: a hole in it is refused as it is anywhere
  moves("table.move(xs, 1, #xs, 1, { 1, nil, 3 })\n", "nil_not_allowed")
end

-- what the declarations say --------------------------------------------------------------------------

--- The display of each declaration of `owner.name` (a library's field) in `r`, in order.
local function declared(r: Programs.Run, owner: string, name: string): {string}
  local out: mut {string} = {}
  if owner == "StandardLibrary" then
    -- The globals of the file are the values `global name <const> = StandardLibrary.name` gives.
    for _, t in ipairs(r.program.values[name] or {}) do
      out[#out + 1] = Types.display(t)
    end
    return out
  end
  local entry = r.program.globals[owner]
  local decl = entry ~= nil and entry.decl or nil
  local body = decl ~= nil and decl.body or nil
  for _, f in ipairs(body ~= nil and body.fields or {}) do
    if f.name == name then
      out[#out + 1] = Types.display(f.type)
    end
  end
  for _, m in ipairs(body ~= nil and body.methods or {}) do
    if m.name == name then
      out[#out + 1] = Types.display(m.type)
    end
  end
  return out
end

local function test_a_function_that_answers_nil_where_lua_does_is_declared_so()
  local r = run("")
  local problems: {string} = {}
  local function same(owner: string, name: string, ...: string)
    local got, want = declared(r, owner, name), { ... }
    if table.concat(got, "\n") ~= table.concat(want, "\n") then
      local problem = owner .. "." .. name .. ":\n" .. table.concat(got, "\n")
      problems[#problems + 1] = problem
    end
  end
  same("string", "byte", "function(string, p2?: integer): integer?", "function(string, integer, p3?: integer): integer...")
  same("string", "find", "function(string, string, p3?: integer, p4?: boolean): integer?, integer?, string...")
  same("string", "match", "function(string, string, p3?: integer): string...")
  same("table", "remove", "function<T>(mut {T}, p2?: integer): T?")
  -- a function that changes the collection it is given declares it `mut`
  same("table", "insert", "function<T>(mut {T}, integer, T)", "function<T>(mut {T}, T)")
  same("table", "sort", "function(mut {integer}, p2?: function(integer, integer): boolean)",
    "function(mut {number}, p2?: function(number, number): boolean)", "function(mut {string}, p2?: function(string, string): boolean)",
    "function<T>(mut {T}, function(T, T): boolean)")
  same("table", "move", "function<T>(mut {T}, integer, integer, integer): mut {T}",
    "function<T>({T}, integer, integer, integer, mut {T}): mut {T}")
  same("StandardLibrary", "rawset", "function<T, U>(mut {T: U}, T, U): mut {T: U}")
  -- `assert` answers its argument without the nil, and its message too where one is given
  same("StandardLibrary", "assert", "function<T>(T?): T", "function<T, U>(T?, U, ...: any): T, U, any...")
  -- the numbers a function takes are numbers, and a call with none is refused
  same("math", "abs", "function(integer): integer", "function(number): number")
  same("math", "max", "function(integer, ...: integer): integer", "function(number, ...: number): number")
  same("math", "min", "function(integer, ...: integer): integer", "function(number, ...: number): number")
  same("math", "tointeger", "function(any): integer?")
  same("math", "type", "function(any): string?")
  same("utf8", "len", "function(string, p2?: number, p3?: number, p4?: boolean): integer?, integer?")
  same("utf8", "offset", "function(string, number, p3?: number): integer?")
  same("io", "open", "function(string, p2?: io.OpenMode): FILE?, string?, integer?")
  same("io", "popen", "function(string, p2?: io.OpenMode): FILE?, string?, integer?")
  same("io", "tmpfile", "function(): FILE?, string?, integer?")
  same("io", "write", "function(...: number | string): FILE?, string?, integer?")
  same("FILE", "close", "function(FILE): boolean?, string?, integer?")
  same("FILE", "flush", "function(FILE): boolean?, string?, integer?")
  same("FILE", "setvbuf", "function(FILE, FILE.SetVBufMode, p3?: integer): boolean?, string?, integer?")
  same("FILE", "write", "function(FILE, ...: number | string): FILE?, string?, integer?")
  -- `os.execute` always answers its three values, the status among them
  same("os", "execute", "function(string): boolean?, string, integer")
  same("os", "rename", "function(string, string): boolean?, string?, integer?")
  same("package", "searchpath", "function(string, string, p3?: string, p4?: string): string?, string?")
  same("package", "loadlib", "function(string, string): ((function(...: any): any...)?, string?, string?)")
  -- a function of `debug` that takes a coroutine takes the typed one
  same("debug", "getinfo", "function<T, U, V>(Coroutine<T, U, V>, (function(...: any): any...), p3?: string): debug.GetInfoTable",
    "function<T, U, V>(Coroutine<T, U, V>, integer, p3?: string): debug.GetInfoTable?",
    "function((function(...: any): any...), p2?: string): debug.GetInfoTable", "function(integer, p2?: string): debug.GetInfoTable?")
  same("debug", "getlocal", "function<T, U, V>(Coroutine<T, U, V>, (function(...: any): any...), integer): string?",
    "function<T, U, V>(Coroutine<T, U, V>, integer, integer): string?, any", "function((function(...: any): any...), integer): string?",
    "function(integer, integer): string?, any")
  same("debug", "gethook", "function<T, U, V>(p1?: Coroutine<T, U, V>): ((function(debug.HookEvent, integer))?, integer)")
  same("debug", "sethook", "function<T, U, V>(Coroutine<T, U, V>, (function(debug.HookEvent, integer)), string, p4?: integer)",
    "function((function(debug.HookEvent, integer)), string, p3?: integer)")
  same("debug", "setlocal", "function<T, U, V>(Coroutine<T, U, V>, integer, integer, any): string?",
    "function(integer, integer, any): string?")
  same("debug", "traceback", "function<T, U, V>(Coroutine<T, U, V>, p2?: string, p3?: integer): string",
    "function(p1?: string, p2?: integer): string", "function(any): any")
  -- no type of the language names a userdata, so the functions that take or answer one say `debug.Userdata`
  same("debug", "getuservalue", "function(debug.Userdata, p2?: integer): any, boolean")
  same("debug", "setuservalue", "function(debug.Userdata, any, integer): debug.Userdata")
  same("debug", "upvalueid", "function((function(...: any): any...), integer): debug.Userdata?")
  same("debug", "getmetatable", "function<T>(T): metatable<T>?")
  same("StandardLibrary", "getmetatable", "function<T>(T): metatable<T>?")
  same("StandardLibrary", "loadfile", "function(p1?: string, p2?: StandardLibrary.LoadMode, p3?: {string: any}): ((function(...: any): any...)?, string?)",
    "function(p1?: string, p2?: string, p3?: {string: any}): ((function(...: any): any...)?, string?)",
    "function<T>(p1?: string, p2?: StandardLibrary.LoadMode, p3?: {string: T}): ((function(...: any): any...)?, string?)",
    "function<T>(p1?: string, p2?: string, p3?: {string: T}): ((function(...: any): any...)?, string?)")
  same("StandardLibrary", "collectgarbage", "function(p1?: StandardLibrary.CollectGarbageCommand): number",
    "function(StandardLibrary.CollectGarbageStep, p2?: integer): boolean",
    "function(StandardLibrary.CollectGarbageMode, p2?: integer, p3?: integer, p4?: integer): string",
    "function(StandardLibrary.CollectGarbageSetValue, integer): number",
    "function(StandardLibrary.CollectGarbageIsRunning): boolean", "function(string, p2?: number): number | string | boolean")
  same("io", "read", "function(): string?", "function(...: FileNumberMode): number...",
    "function(...: number | FileStringMode): string...", "function(...: number | FileMode): number | string...",
    "function(...: number | string): string...")
  same("os", "getenv", "function(string): string?")
  same("os", "remove", "function(string): boolean?, string?, integer?")
  same("FILE", "seek", "function(FILE, p2?: FILE.SeekWhence, p3?: integer): integer?, string?, integer?")
  same("StandardLibrary", "tonumber", "function(any): number?", "function(any, integer): integer?")
  same("StandardLibrary", "load", "function(string | (function(): string?), p2?: string, p3?: StandardLibrary.LoadMode, " ..
      "p4?: {string: any}): ((function(...: any): any...)?, string?)", "function(string | (function(): string?), p2?: string, " ..
      "p3?: string, p4?: {string: any}): ((function(...: any): any...)?, string?)",
    "function<T>(string | (function(): string?), p2?: string, p3?: StandardLibrary.LoadMode, " ..
      "p4?: {string: T}): ((function(...: any): any...)?, string?)", "function<T>(string | (function(): string?), p2?: string, " ..
      "p3?: string, p4?: {string: T}): ((function(...: any): any...)?, string?)")
  same("StandardLibrary", "rawget", "function<T, U>({T: U}, T): U?", "function(any, any): any")
  -- the array of the values `table.pack` packs, and `table.unpack` of an array
  same("table", "pack", "function<T>(...: T): table.PackTable<T>", "function(...: any): table.PackTable<any>")
  same("table", "unpack", "function<T>({T}, p2?: number, p3?: number): T...")
  -- unchanged: the values past the first of a `select` and the captures of a match are tails, read `T?` as one value
  same("StandardLibrary", "select", "function<T>(integer, ...: T): T...", "function(integer, ...: any): any...",
    "function(string, ...: any): integer")
  same("StandardLibrary", "next", "function<T, U>({T: U}, p2?: T): T?, U?", "function<T>({T}, p2?: integer): integer?, T?")
  assert(#problems == 0, table.concat(problems, "\n"))
end

--- A statement or two on one line, and the codes the checker finds on that line (space separated, "" for none).
local record Line
  source: string
  codes: string
end

--- Checks the programs of `lines` together, the standard library lowered once: each is a line of its own, and has the
--- errors `codes` says.
local function lines_have(lines: {Line}): Programs.Run
  local sources: mut {string} = {}
  for i, line in ipairs(lines) do
    sources[i] = line.source
  end
  local r = run(table.concat(sources, "\n") .. "\n")
  local found: mut {integer: {string}} = {}
  for _, e in ipairs(r.errors) do
    local at = found[e.y] or {}
    at[#at + 1] = e.code
    found[e.y] = at
  end
  local problems: mut {string} = {}
  for i, line in ipairs(lines) do
    local got = table.concat(found[i] or {}, " ")
    if got ~= line.codes then
      problems[#problems + 1] = line.source .. ": " .. got .. ", wanted " .. line.codes
    end
  end
  assert(#problems == 0, table.concat(problems, "\n"))
  return r
end

local function test_a_use_of_a_result_that_may_be_nil_is_held_to_it_and_a_test_or_a_default_lets_it_stand()
  local _ = lines_have({
    { source = "local s: string = \"abc\"", codes = "" },
    { source = "local at: integer = s:find(\"b\")", codes = "nil_not_allowed" },
    { source = "local after = s:find(\"b\") + 1", codes = "nil_not_allowed" },
    { source = "local first, last = s:find(\"b\") local width: integer = last - first", codes = "nil_not_allowed nil_not_allowed" },
    { source = "local n: integer = tonumber(\"1\")", codes = "not_assignable" },
    { source = "local m: number = tonumber(\"1\")", codes = "nil_not_allowed" },
    { source = "local k: integer = math.tointeger(1.5)", codes = "nil_not_allowed" },
    { source = "local b: integer = s:byte(1)", codes = "nil_not_allowed" },
    { source = "local c: string = string.char(s:byte(1, 2))", codes = "" },
    { source = "local f = io.open(\"x\") local g = f:read()", codes = "nil_not_allowed" },
    { source = "local home: string = os.getenv(\"HOME\")", codes = "nil_not_allowed" },
    { source = "local len: integer = utf8.len(\"x\")", codes = "nil_not_allowed" },
    { source = "local at2: integer = s:find(\"b\") or 0", codes = "" },
    { source = "if s:find(\"b\") then end if s:find(\"b\") == nil then end local found = s:find(\"b\") ~= nil", codes = "" },
    { source = "local n2: integer = tonumber(\"1\", 16) or 0 local m2: number = tonumber(\"1\") or 0", codes = "" },
    { source = "local at3 = s:find(\"b\") local same = at3 == 2", codes = "" },
    { source = "if math.tointeger(2.0) then end local n3: integer = math.tointeger(2.0) or 0", codes = "" },
    { source = "local line = io.read() if line == nil then end", codes = "" },
  })
end

local function test_a_match_answers_the_captures_it_found_and_load_a_chunk_or_nil_and_a_message()
  local r = lines_have({
    { source = "local s: string = \"abc\"", codes = "" },
    { source = "local one = s:match(\"b\")", codes = "" },
    { source = "local a, b = s:match(\"(a)(b)\")", codes = "" },
    { source = "local sure: string = s:match(\"b\")", codes = "nil_not_allowed" },
    { source = "local chunk, why = load(\"return 1\")", codes = "" },
    { source = "local called = load(\"return 1\") called()", codes = "nil_not_allowed" },
    -- a call that succeeds answers its first value alone: the later ones are nil
    { source = "local file, failure = io.open(\"x\") local told: string = failure", codes = "nil_not_allowed" },
    { source = "local count, position = utf8.len(\"x\") local at: integer = position", codes = "nil_not_allowed" },
    { source = "local made, message = load(\"x\") local said: string = message", codes = "nil_not_allowed" },
    { source = "local info = debug.getinfo(5, \"S\") local name = info.source", codes = "nil_not_allowed" },
    { source = "local again = chunk", codes = "" },
  })
  assert(Types.display(Programs.var(r, "one")) == "string?")
  assert(Types.display(Programs.var(r, "a")) == "string?" and Types.display(Programs.var(r, "b")) == "string?")
  assert(Types.display(Programs.var(r, "chunk")) == "(function(...: any): any...)?")
  assert(Types.display(Programs.var(r, "why")) == "string?")
end

local function test_a_gsub_callback_is_typed_by_the_number_of_captures_it_takes()
  local _ = lines_have({
    { source = "local s: string = \"abc\"", codes = "" },
    { source = "local a = s:gsub(\"b\", function(c: string): string return c end)", codes = "" },
    { source = "local a1 = s:gsub(\"b\", function(c) return c end)", codes = "" },
    { source = "local a2 = s:gsub(\"b\", function(): string return \"x\" end)", codes = "" },
    { source = "local a3 = s:gsub(\"(a)(b)\", function(x: string, y: string): string return x .. y end)", codes = "" },
    { source = "local a4 = s:gsub(\"(a)(b)(c)\", function(x: string, y: string, z: string): number return 1 end)", codes = "" },
    -- a callback may keep the match by answering nil
    { source = "local a5 = s:gsub(\"b\", function(c: string): string? return nil end)", codes = "" },
    -- a function that is not a literal passes the same way
    { source = "local function upper(c: string): string return c:upper() end local a6 = s:gsub(\"b\", upper)", codes = "" },
    -- a callback of the wrong parameter type, one that answers a value no replacement is, and one that takes more
    -- captures than an overload does
    { source = "local a7 = s:gsub(\"b\", function(c: integer): string return \"\" end)", codes = "not_assignable" },
    { source = "local a8 = s:gsub(\"b\", function(c: string): boolean return true end)", codes = "not_assignable" },
    { source = "local a9 = s:gsub(\"b\", function(w: string, x: string, y: string, z: string): string return w end)",
      codes = "overload_none" },
  })
end

local function test_collectgarbage_step_answers_whether_the_cycle_ended_and_a_setting_or_a_mode_the_previous_one()
  local r = lines_have({
    { source = "local ended = collectgarbage(\"step\", 0)", codes = "" },
    { source = "local kb = collectgarbage(\"count\")", codes = "" },
    { source = "local old = collectgarbage(\"setpause\", 100)", codes = "" },
    { source = "local mode = collectgarbage(\"incremental\")", codes = "" },
    { source = "local other = collectgarbage(\"generational\", 20, 100)", codes = "" },
  })
  assert(Types.display(Programs.var(r, "ended")) == "boolean" and Types.display(Programs.var(r, "kb")) == "number" and
      Types.display(Programs.var(r, "old")) == "number" and Types.display(Programs.var(r, "mode")) == "string" and
      Types.display(Programs.var(r, "other")) == "string")
end

local function test_pcall_and_xpcall_are_declared_for_the_arities_and_answers_the_tree_uses_and_no_more()
  local _ = lines_have({
    { source = "local function f6(a: integer, b: integer, c: integer, d: integer, e: integer, g: integer): integer return a end", codes = "" },
    { source = "local function f7(a: integer, b: integer, c: integer, d: integer, e: integer, g: integer, h: integer): integer return a end", codes = "" },
    { source = "local function r3(): (integer, integer, integer) return 1, 2, 3 end", codes = "" },
    { source = "local function r4(): (integer, integer, integer, integer) return 1, 2, 3, 4 end", codes = "" },
    { source = "local p6, _p6 = pcall(f6, 1, 2, 3, 4, 5, 6)", codes = "" },
    { source = "local p7, _p7 = pcall(f7, 1, 2, 3, 4, 5, 6, 7)", codes = "overload_none" },
    { source = "local p3, _p3 = pcall(r3)", codes = "" },
    { source = "local p4, _p4 = pcall(r4)", codes = "overload_none" },
    { source = "local x3, _x3 = xpcall(f6, function(m: any): string return \"\" end, 1, 2, 3, 4, 5, 6)", codes = "overload_none" },
    { source = "local x2, _x2 = xpcall(r3, function(m: any): string return \"\" end)", codes = "" },
    { source = "local x4, _x4 = xpcall(r4, function(m: any): string return \"\" end)", codes = "overload_none" },
  })
end

local function test_table_sort_without_a_comparator_takes_numbers_and_strings_only()
  local r = lines_have({
    { source = "local record P n: integer end", codes = "" },
    { source = "local ps: mut {P} = { { n = 2 }, { n = 1 } }", codes = "" },
    { source = "table.sort(ps)", codes = "overload_none" },
    { source = "table.sort(ps, function(a: P, b: P): boolean return a.n < b.n end)", codes = "" },
    { source = "local bs: mut {boolean} = { true, false }", codes = "" },
    { source = "table.sort(bs)", codes = "overload_none" },
    { source = "local mixed: mut {integer | string} = { 1, \"a\" }", codes = "" },
    { source = "table.sort(mixed)", codes = "overload_none" },
    { source = "local ns: mut {integer} = { 2, 1 }", codes = "" },
    { source = "table.sort(ns)", codes = "" },
    { source = "table.sort(ns, function(a: integer, b: integer): boolean return a > b end)", codes = "" },
    { source = "local fs: mut {number} = { 2.5, 1 }", codes = "" },
    { source = "table.sort(fs)", codes = "" },
    { source = "local ss: mut {string} = { \"b\", \"a\" }", codes = "" },
    { source = "table.sort(ss)", codes = "" },
  })
  local _ = r
  -- The fix says what to pass.
  local bad = run("local record P n: integer end\nlocal ps: mut {P} = {}\ntable.sort(ps)\n")
  assert(#bad.errors == 1 and bad.errors[1].code == "overload_none", Programs.codes(bad))
  local refusal = assert(bad.errors[1], "the refusal of the sort")
  assert(refusal.fix:find("pass a comparator", 1, true) ~= nil, refusal.fix)
end

local function test_the_typed_coroutine_records_can_be_written_against_the_real_declarations()
  local r = lines_have({
    { source = "local function body(h: Yielder<integer, nil>): string return \"done\" end", codes = "" },
    { source = "local co: Coroutine<integer, string, nil> = coroutine.create(body)", codes = "" },
  })
  assert(#r.before == 0, table.concat(r.before, " "))
end

local function test_the_declaration_files_have_no_error_of_their_own()
  local found = Programs.declared(prelude(), stdlib())
  assert(#found == 0, table.concat(found, "\n"))
  -- a program checked against them never sees an error of a declaration, so the check must: it names one planted in the file
  local planted = Programs.declared(prelude(), stdlib() .. "\nglobal record Planted\n  n: {number: integer}\nend\n")
  assert(#planted == 1 and planted[1] == "lang/stdlib.d.tl: float_key", table.concat(planted, "\n"))
  local broken = Programs.declared("do\n  global record Seen\n    n: {number: integer}\n  end\nend\n", stdlib())
  assert(broken[1] == "lang/prelude.d.tl: float_key", table.concat(broken, "\n"))
end

local function test_a_file_is_a_userdata_record_and_a_debug_function_takes_a_typed_coroutine()
  local _ = lines_have({
    { source = "local made: FILE = {}", codes = "literal_shape" },
    { source = "local co = coroutine.create(function() end)", codes = "" },
    { source = "local trace: string = debug.traceback(co)", codes = "" },
    { source = "local info = debug.getinfo(co, 1, \"l\")", codes = "" },
    { source = "local function f(...: any): any... return ... end local id = debug.upvalueid(f, 1)", codes = "" },
    { source = "local value = debug.getuservalue(id)", codes = "nil_not_allowed" },
    { source = "local other = debug.getuservalue(5)", codes = "not_assignable" },
  })
end

local function test_load_takes_a_table_as_the_environment_of_the_chunk_and_an_empty_literal_is_typed_by_it()
  local _ = lines_have({
    { source = "local made, why = load(\"return 1\", \"=chunk\", \"t\", {})", codes = "" },
    { source = "local env: {string: any} = {}", codes = "" },
    { source = "local again = load(\"return 1\", \"=chunk\", \"t\", env)", codes = "" },
    { source = "local bare = load(\"return 1\")", codes = "" },
    -- a table of a value type that is none is the environment of a chunk too
    { source = "local counts: {string: integer} = { answer = 40 }", codes = "" },
    { source = "local counted = load(\"return answer\", \"=chunk\", \"t\", counts)", codes = "" },
    { source = "local words: {string: string} = { name = \"x\" }", codes = "" },
    { source = "local named = loadfile(\"chunk.lua\", \"t\", words)", codes = "" },
    -- a value that is no table faults at run time, and no overload takes it
    { source = "local five = load(\"return 1\", \"=chunk\", \"t\", 5)", codes = "overload_none" },
    { source = "local oops = load(\"return 1\", \"=chunk\", \"t\", \"oops\")", codes = "overload_none" },
    { source = "local file_five = loadfile(\"chunk.lua\", \"t\", 5)", codes = "overload_none" },
  })
end

--- The Lua of an accepted `load` with an environment runs and reads the environment it was given.
local function test_a_chunk_loaded_with_a_table_environment_runs_in_it()
  local r = run("local env: {string: integer} = { answer = 40 }\n" ..
      "local chunk = load(\"return answer + 2\", \"=chunk\", \"t\", env)\n" ..
      "assert(chunk ~= nil)\n" ..
      "assert(tostring(chunk()) == \"42\")\n")
  assert(#r.errors == 0, Programs.codes(r))
  -- the program raises where the chunk did not read the environment it was given
  local program = assert(load(Programs.lua(r), "=t"))
  program()
end

local function test_a_table_unpacks_to_its_element_type_and_packs_to_the_array_of_what_it_was_given()
  local r = lines_have({
    { source = "local ns: {integer} = { 1, 2 }", codes = "" },
    { source = "local first, second = table.unpack(ns)", codes = "" },
    { source = "local packed = table.pack(1, 2)", codes = "" },
    { source = "local count: integer = packed.n", codes = "" },
  })
  assert(Types.display(Programs.var(r, "first")) == "integer?" and Types.display(Programs.var(r, "packed")) == "table.PackTable<integer>")
end

--- Every global and library member with its type is held to testdata/stdlib/globals.txt, so that an edit of a declaration shows
--- as a diff, a widening to `any` included, which no program of the tree contradicts. Refresh it, after reading the diff, with
--- `bin/cosmic lang/stdlib_golden.tl`.
local function test_the_lowered_declarations_are_the_golden_ones()
  local golden = assert(Fs.read("testdata/stdlib/globals.txt"))
  local now = Programs.dump(prelude(), stdlib())
  assert(#golden > 15000, "the golden holds too little to hold the declarations to")
  local wanted = golden:gmatch("[^\n]+")
  local at = 0
  for line in now:gmatch("[^\n]+") do
    at = at + 1
    local want = wanted()
    assert(want == line, "line " .. tostring(at) .. " of the declarations is `" .. line .. "`, the golden's `" .. tostring(want) ..
        "`: refresh testdata/stdlib/globals.txt with `bin/cosmic lang/stdlib_golden.tl` after reading the diff")
  end
  local more = 0
  for _ in wanted do
    more = more + 1
  end
  assert(more == 0, "the golden has " .. tostring(more) .. " more lines than the declarations: refresh it with `bin/cosmic lang/stdlib_golden.tl`")
end

local function test_an_enum_or_a_union_of_enums_calls_the_functions_of_string()
  local head = "local enum Kind\n  \"a\"\nend\nlocal enum Other\n  \"b\"\nend\nlocal k: Kind = \"a\"\n"
  local r = run(head .. "local function f(u: Kind | Other, v: Kind | string)\n" ..
      "  assert(u:len() + v:len() > 0)\nend\nlocal x = k:rep(2)\nlocal n = k:len()\n")
  assert(#r.errors == 0, Programs.codes(r))
  assert(Types.display(Programs.var(r, "x")) == "string")
  assert(Types.display(Programs.var(r, "n")) == "integer")
  assert(Programs.codes(run(head .. "local x: Kind = k:rep(2)\n")) == "not_assignable")
end
