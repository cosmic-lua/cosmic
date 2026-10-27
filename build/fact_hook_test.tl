--- The `__fact` hook of the test worker ([`worker.install_checks`]): the calls the new checker's code generator writes at
--- the reads a test narrowed ([`lang.fact_wraps`]) answer their value where the conclusion holds, and where it is false
--- of the value they fail the read and keep a violation of kind "fact", the row `cosmic test --check-types` lists
--- (`type_violations`). The programs are compiled with the wraps and run in this process, beside the fork's checks
--- (build.checked_narrowing_test).
local Test = require("cosmic.test")
local programs = require("build.fact_programs")
local worker = require("build.test_worker")

Test.policy{}

--- The facts violated after the first `before` violations. A checked run also reports the boundaries this file's own
--- functions cross (parameters, return values, fields: kinds `parameter`, `return` and `field`), which are not what
--- the program under test did.
local function since(before: integer): {worker.Violation}
  local met = worker.violations()
  local out: mut {worker.Violation} = {}
  for i = before + 1, #met do
    local each = met[i]
    if each ~= nil and each.kind == "fact" then out[#out + 1] = each end
  end
  return out
end

local function spelled(met: worker.Violation?): string
  if met == nil then return "no row" end
  return table.concat({ met.kind, met.at, met.target, met.declared, met.actual, tostring(met.count) }, " | ")
end

local function count_of(text: string, what: string): integer
  local n = 0
  for _ in text:gmatch(what) do n = n + 1 end
  return n
end

local function test_a_fact_that_holds_answers_its_value_and_records_nothing()
  local fact = worker.fact
  local before = #worker.violations()
  assert(fact("a", "nil", "x", nil, nil, nil, nil, "held.tl:1:1") == "a")
  assert(fact(false, "nil", "x", nil, nil, nil, nil, "held.tl:1:2") == false, "false is a value")
  assert(fact(1.5, "nil,string", "n", nil, nil, nil, nil, "held.tl:1:3") == 1.5)
  assert(fact("red", "number", "c", { "red", "green" }, nil, nil, nil, "held.tl:2:1") == "red")
  local class = {}
  local pet = setmetatable({}, class)
  assert(fact(pet, "nil", "p", nil, { {}, class }, nil, nil, "held.tl:3:1") == pet)
  local square = { kind = "sq" }
  assert(fact(square, "nil", "s", nil, nil, "kind", { "sq" }, "held.tl:4:1") == square)
  assert(#since(before) == 0, "a fact that held was recorded")
end

--- What the Lua `text` returns, made in Lua since the type of a metatable has no `__metatable` field to write.
local function evaluated(text: string): any, any
  return assert(load(text))()
end

--- The class of a value is read as the generated test `@p == Dog` reads it, whatever the class's `__metatable` says: a
--- class that hides its metatable is no false "fact violated", and a value of another class is still one.
local function test_a_class_that_hides_its_metatable_is_read_as_the_generated_test_reads_it()
  local before = #worker.violations()
  local hidden, pet = evaluated("local class = { __metatable = \"locked\" } return class, setmetatable({}, class)")
  assert(worker.fact(pet, "nil", "p", nil, { hidden }, nil, nil, "hidden.tl:1:1") == pet)
  assert(#since(before) == 0, "a class that hides its metatable was refused")
  local stranger = evaluated("return setmetatable({}, { __metatable = \"locked\" })")
  local ok, message = pcall(function(): any
    local v = worker.fact(stranger, "nil", "p", nil, { hidden }, nil, nil, "hidden.tl:2:1")
    return v
  end)
  assert(not ok, "a value of another class passed")
  assert(message == "fact violated at hidden.tl:2:1: p is a table of another class, the checker proved a table of one of its classes",
    tostring(message))
  local met = since(before)
  assert(#met == 1, tostring(#met) .. " rows")
  assert(spelled(met[1]) == "fact | hidden.tl:2:1 | p | a table of one of its classes | a table of another class | 1",
    spelled(met[1]))
end

--- Calls the hook with a value that the conclusion is false of: it raises, naming the read and what was seen, and
--- keeps one row.
local function refuses(index: integer, value: any, taken: string, strings: {string}?, classes: {any}?,
                       tag: string?, tags: ({string} | string)?, actual: string, declared: string)
  local at = "false.tl:" .. tostring(index) .. ":9"
  local before = #worker.violations()
  local ok, message = pcall(function(): any
    local v = worker.fact(value, taken, "place", strings, classes, tag, tags, at)
    return v
  end)
  assert(not ok, "case " .. tostring(index) .. " passed")
  local expected = "fact violated at " .. at .. ": place is " .. actual .. ", the checker proved " .. declared
  assert(message == expected, tostring(message) .. " against " .. expected)
  local met = since(before)
  assert(#met == 1, "case " .. tostring(index) .. " kept " .. tostring(#met) .. " rows")
  local want = "fact | " .. at .. " | place | " .. declared .. " | " .. actual .. " | 1"
  assert(spelled(met[1]) == want, spelled(met[1]) .. " against " .. want)
end

--- Each shape of conclusion, a value it is false of, the place the read is at, and the message and the row that come of it.
local function test_a_false_fact_fails_the_read_and_is_recorded()
  local class = {}
  refuses(1, nil, "nil", nil, nil, nil, nil, "nil", "not nil")
  refuses(2, 2, "nil,number", nil, nil, nil, nil, "integer", "not nil|number")
  refuses(3, 2.5, "number", nil, nil, nil, nil, "float", "not number")
  refuses(4, true, "boolean", nil, nil, nil, nil, "boolean", "not boolean")
  refuses(5, "purple", "number", { "red", "green" }, nil, nil, nil, "string \"purple\"", "one of red|green")
  refuses(6, setmetatable({}, {}), "nil", nil, { class }, nil, nil, "a table of another class",
    "a table of one of its classes")
  refuses(7, { kind = "ci" }, "nil", nil, nil, "kind", { "sq" }, "a table whose kind is string \"ci\"",
    "kind one of sq")
  refuses(8, { kind = "ci" }, "nil", nil, nil, "kind", "sq,tr", "a table whose kind is string \"ci\"", "kind one of sq|tr")
  refuses(9, { kind = 3 }, "nil", nil, nil, "kind", "sq,tr", "a table whose kind is integer", "kind one of sq|tr")
  -- The joined text of the values is the set of them, and a member of it passes.
  assert(worker.fact({ kind = "tr" }, "nil", "place", nil, nil, "kind", "sq,tr", "ok.tl:1:1") ~= nil)
end

--- Whether the hook fails a read of nil that the checker took to be none at `at`, which names it `name`.
local function fails_on_nil(name: string, at: string): boolean
  local ok, _ = pcall(function(): any
    local v = worker.fact(nil, "nil", name, nil, nil, nil, nil, at)
    return v
  end)
  return not ok
end

local function test_the_same_read_again_counts_up_its_row()
  local before = #worker.violations()
  for _ = 1, 3 do
    assert(fails_on_nil("x", "again.tl:5:2"))
  end
  assert(fails_on_nil("y", "again.tl:5:2"))
  local met = since(before)
  assert(#met == 2, tostring(#met) .. " rows")
  assert(spelled(met[1]) == "fact | again.tl:5:2 | x | not nil | nil | 3", spelled(met[1]))
  assert(spelled(met[2]) == "fact | again.tl:5:2 | y | not nil | nil | 1", spelled(met[2]))
end

--- A call that names no place is placed by the frame that made it: the file and line of the read.
local function test_a_read_with_no_place_is_placed_by_its_caller()
  local before = #worker.violations()
  local ok, _ = pcall(function(): any
    local v = worker.fact(nil, "nil", "x")
    return v
  end)
  assert(not ok)
  local met = since(before)
  assert(#met == 1, tostring(#met) .. " rows")
  local first = met[1]
  assert(first ~= nil and first.at:find("fact_hook_test[^:]*:%d+$") ~= nil, spelled(first))
end

--- Past `most_kept` distinct violations a worker only counts, as for the fork's checks.
local function test_violations_past_the_limit_are_counted_not_kept()
  local kept, dropped, limit = #worker.violations(), worker.dropped_violations(), worker.most_kept
  worker.most_kept = kept + 1
  assert(fails_on_nil("x", "limit.tl:1:1"))
  assert(fails_on_nil("y", "limit.tl:1:1"))
  worker.most_kept = limit
  assert(#since(kept) == 1 and worker.dropped_violations() == dropped + 1)
end

--- The program is compiled with the checks or without: the same lines, and the wraps only in the first.
local function test_a_compile_with_facts_writes_the_wraps_and_without_none()
  local with = programs.compiled("sound.tl", programs.sound, true)
  local without = programs.compiled("sound.tl", programs.sound, false)
  assert(not without:find("__fact", 1, true), without)
  assert(count_of(with, "__fact%(") == 1, with)
  assert(with:find("__fact(x, \"nil\", \"x\", nil, nil, nil, nil, \"sound.tl:5:10\")", 1, true) ~= nil, with)
  -- the one definition it brings along is on the first line
  assert(with:find("^if not __fact then __fact = function%(v%) return v end end ") ~= nil, with)
  assert(count_of(with, "\n") == count_of(without, "\n"), "the wraps moved a line")
end

local record Api
  read: function(string?, function()): string
end

local record Shapes
  paint: function(any): string
  pet: function(any): string
  area: function(any): integer
  area_after: function(any, function()): integer
  area_between: function(any, function()): integer
  tag_only: function(any, function()): string
  all_return: function(any): integer
  all_assign: function(any): integer
  pet_after: function(any, function()): string
  dog: function(): any
  cat: function(): any
  square: function(): any
  circle: function(): any
end

--- The Lua of `name` run in an environment of the standard library, where `assert` is Lua's or, where `lax`, one that
--- does not raise.
local function loaded(code: string, name: string, lax: boolean): any
  local env: mut {string:any} = {}
  if lax then
    env["assert"] = function(...: any): any...
      return ...
    end
  end
  setmetatable(env, { __index = _G })
  return assert(load(code, "=" .. name, "t", env))()
end

local function nothing() end

--- A checked run's worker defines the hooks as globals, where the Lua of the wraps and of the parameter checks finds them.
local function test_the_worker_defines_the_hook_the_wraps_call()
  worker.install_checks()
  assert(loaded("return __fact", "hook", false) == worker.fact)
  assert(loaded("return __cosmic_tc", "hook", false) ~= nil)
end

--- A chunk with wraps brings the definition of the hook it calls, for a process with none (one a test starts, a library
--- the worker loads before it installs its own): the call answers its value, as the fork's `(__cosmic_tc or select)` does.
local function test_a_wrapped_chunk_defines_the_hook_it_calls_where_none_is_defined()
  local code = programs.compiled("sound.tl", programs.sound, true)
  local definition = code:match("^(if not __fact then __fact = function%(v%) return v end end )")
  assert(definition ~= nil, code)
  -- run alone, in a table of its own, where nothing else defines the global
  local answered = assert(load(definition .. "return __fact(41)", "=definition", "t", {}))()
  assert(answered == 41)
end

--- A correct program: the narrowed reads are checked, and nothing is recorded.
local function test_a_sound_program_runs_checked_and_records_nothing()
  worker.install_checks()
  local before = #worker.violations()
  local api = loaded(programs.compiled("sound.tl", programs.sound, true), "sound.tl", false) as Api
  assert(api.read("a", nothing) == "a" and api.read(nil, nothing) == "none")
  assert(#since(before) == 0, "a sound read was recorded")
end

--- An `assert` that does not raise leaves the nil the checker took away: the read is one row and fails.
local function test_a_narrowing_planted_by_a_lax_assert_is_one_row()
  worker.install_checks()
  local before = #worker.violations()
  local api = loaded(programs.compiled("unsound_assert.tl", programs.unsound_assert, true), "unsound_assert.tl", true) as Api
  assert(api.read("a", nothing) == "a", "a read the fact holds of was refused")
  assert(#since(before) == 0)
  for _ = 1, 2 do
    local ok, message = pcall(api.read, nil, nothing)
    assert(not ok and message == "fact violated at unsound_assert.tl:3:10: x is nil, the checker proved not nil", tostring(message))
  end
  local met = since(before)
  assert(#met == 1, tostring(#met) .. " rows")
  assert(spelled(met[1]) == "fact | unsound_assert.tl:3:10 | x | not nil | nil | 2", spelled(met[1]))
end

local record Box
  mut value: string?
end

local record TagMember
  kind: string
end

local record TagBox
  mut s: TagMember
end

local record PokeApi
  read: function(Box, function()): string
end

--- A path of a fixed field is narrowed by its test; a function that clears the field behind the checker's back is a lie
--- the read of the path finds.
local function test_a_narrowing_planted_by_a_cast_write_is_one_row()
  worker.install_checks()
  local before = #worker.violations()
  local api = loaded(programs.compiled("unsound_poke.tl", programs.unsound_poke, true), "unsound_poke.tl", false) as PokeApi
  local box: Box = { value = "kept" }
  assert(api.read(box, nothing) == "kept")
  assert(#since(before) == 0, "a field that stayed was recorded")
  local ok, message = pcall(api.read, box, function() box.value = nil end)
  assert(not ok and message == "fact violated at unsound_poke.tl:7:12: b.value is nil, the checker proved not nil", tostring(message))
  local met = since(before)
  assert(#met == 1, tostring(#met) .. " rows")
  assert(spelled(met[1]) == "fact | unsound_poke.tl:7:12 | b.value | not nil | nil | 1", spelled(met[1]))
end

--- The wraps of a class and a tag are called with the class tables and the field values the checker concluded, and the
--- hook holds the values the program makes to them.
local function test_the_wraps_of_a_class_and_a_tag_hold_of_the_values_that_meet_them()
  worker.install_checks()
  local before = #worker.violations()
  local code = programs.compiled("shapes.tl", programs.shapes, true)
  assert(code:find("\"kind\", \"square\"", 1, true) ~= nil and code:find("{Dog}", 1, true) ~= nil, code)
  local api = loaded(code, "shapes.tl", false) as Shapes
  assert(api.paint("red") == "red" and api.paint(3) == "3")
  assert(api.pet(api.dog()) == "rex" and api.pet(api.cat()) == "other" and api.pet(nil) == "other")
  assert(api.area(api.square()) == 4 and api.area(api.circle()) == 0)
  assert(#since(before) == 0, "a fact that holds was recorded")
end

--- A class and a tag are conclusions of a test as a kind is: a function that changes the value between the test and the read
--- makes them false, and each is one row.
local function test_a_class_and_a_tag_planted_false_are_one_row_each()
  worker.install_checks()
  local before = #worker.violations()
  local api = loaded(programs.compiled("shapes.tl", programs.shapes, true), "shapes.tl", false) as Shapes
  local square = api.square() as {string:any}
  local dog = api.dog() as {string:any}
  assert(api.area_after(square, nothing) == 4 and api.pet_after(dog, nothing) == "rex")
  assert(#since(before) == 0, "a conclusion that held was recorded")
  local ok, message = pcall(api.area_after, square, function() square["kind"] = "circle" end)
  assert(not ok and tostring(message) == "fact violated at shapes.tl:42:12: s is a table whose kind is string \"circle\", " ..
      "the checker proved kind one of square", tostring(message))
  local ok_dog, message_dog = pcall(api.pet_after, dog, function() setmetatable(dog, nil) end)
  assert(not ok_dog and message_dog == "fact violated at shapes.tl:49:12: p is a table of another class, the checker proved " ..
      "a table of one of its classes", tostring(message_dog))
  local met = since(before)
  assert(#met == 2, tostring(#met) .. " rows")
  assert(spelled(met[1]) == "fact | shapes.tl:42:12 | s | kind one of square | a table whose kind is string \"circle\" | 1",
    spelled(met[1]))
  assert(spelled(met[2]) == "fact | shapes.tl:49:12 | p | a table of one of its classes | a table of another class | 1",
    spelled(met[2]))
  -- A narrowing read before a call and after it is checked at both: the read before holds, and the one after meets the plant.
  square["kind"] = "square"
  assert(api.area_between(square, nothing) == 8)
  assert(#since(before) == 2, "a conclusion that held was recorded")
  local ok_between, message_between = pcall(api.area_between, square, function()
    square["kind"] = "circle"
  end)
  assert(not ok_between and tostring(message_between):find("fact violated at shapes.tl:", 1, true) == 1 and
      tostring(message_between):find("the checker proved kind one of square", 1, true) ~= nil, tostring(message_between))
  assert(#since(before) == 3, tostring(#since(before)) .. " rows")
  -- The read of a tag is a read of a narrowed place: after a test of `b.s.kind` the remainder is what the read after the
  -- call has, and a function that puts a member back is met there, though nothing else reads `b.s` after it.
  local box: TagBox = { s = { kind = "b" } }
  assert(api.tag_only(box, nothing) == "b")
  assert(#since(before) == 3, "a conclusion that held was recorded")
  local ok_tag, message_tag = pcall(api.tag_only, box, function() box.s = { kind = "a" } end)
  assert(not ok_tag and tostring(message_tag):find("fact violated at shapes.tl:", 1, true) == 1 and
      tostring(message_tag):find("kind one of c|b", 1, true) ~= nil, tostring(message_tag))
  assert(#since(before) == 4, tostring(#since(before)) .. " rows")
  -- The false side of the last test of a chain that names every member is empty, and the checker relies on it: a value
  -- of no member is met at that test, in the form that returns from each arm and in the form that assigns.
  local member: TagMember = { kind = "b" }
  assert(api.all_return(member) == 2 and api.all_assign(member) == 2)
  assert(#since(before) == 4, "a conclusion that held was recorded")
  local stray: TagMember = { kind = "zz" }
  local ok_return, message_return = pcall(api.all_return, stray)
  assert(not ok_return and tostring(message_return):find("fact violated at shapes.tl:", 1, true) == 1, tostring(message_return))
  local ok_assign, message_assign = pcall(api.all_assign, stray)
  assert(not ok_assign and tostring(message_assign):find("fact violated at shapes.tl:", 1, true) == 1, tostring(message_assign))
  assert(#since(before) == 6, tostring(#since(before)) .. " rows")
end
