--- The run-time checks a checked test run compiles in (`cosmic test
--- --check-types`, [`importer.compile`]'s `checks`): which declared
--- boundaries they write into the Lua, and what the hook
--- ([`worker.install_checks`]) reports of a value that crosses one as a
--- kind its type does not admit. The compile's keys and the executables
--- that never carry a check are in build/runtime_checks_keys_test.tl and
--- build/runtime_checks_tool_test.tl.

local teal = require("build.teal")
local worker = require("build.test_worker")

local source = table.concat({
  "local record Box",
  "  name: string",
  "  count: integer",
  "  note?: string",
  "end",
  "local record Mod",
  "end",
  "local function greet(who: string, times: integer, note?: string): string",
  "  return who",
  "end",
  "function Mod.call_greet(v: any)",
  "  greet(v as string, 1)",
  "end",
  "function Mod.call_greet_again(v: any)",
  "  greet(v as string, 1)",
  "end",
  "function Mod.dup(_: string, _: integer)",
  "end",
  "function Mod.call_times(v: any)",
  "  greet(\"x\", v as integer)",
  "end",
  "function Mod.call_note(v: any)",
  "  greet(\"x\", 1, v as string)",
  "end",
  "function Mod.call_box(box: Box): any",
  "  return box",
  "end",
  "function Mod.lookup(m: {string:string}, key: string): string",
  "  return m[key]",
  "end",
  "function Mod.both(ok: boolean): boolean, string",
  "  return ok",
  "end",
  "function Mod.maybe(m: {string:string}, key: string): string | nil",
  "  return m[key]",
  "end",
  "function Mod.same<T>(value: T): T",
  "  return value",
  "end",
  "function Mod.anything(value: any): any",
  "  return value",
  "end",
  "function Mod.set_name(box: Box, v: any)",
  "  box.name = v as string",
  "end",
  "function Mod.set_count(box: Box, v: any)",
  "  box.count = v as integer",
  "end",
  "function Mod.set_note(box: Box, v: any)",
  "  box.note = v as string",
  "end",
  "function Mod.fail(): string",
  "  error(\"boom\", 2)",
  "  return \"\"",
  "end",
  "function Mod.relay(): string",
  "  return Mod.fail()",
  "end",
  "function Mod.relay_lookup(m: {string:string}, key: string): string",
  "  return Mod.lookup(m, key)",
  "end",
  "function Mod.new_box(): Box",
  "  return { name = \"a\", count = 1 }",
  "end",
  "return Mod",
  "",
}, "\n")

--- The line of `source` that holds `text`.
local function line_of(text: string): integer
  local line = 0
  for each in (source .. "\n"):gmatch("([^\n]*)\n") do
    line = line + 1
    if each:find(text, 1, true) then return line end
  end
  error("no line holds " .. text)
end

--- `source` compiled with the checks, or without, as Lua text, as the
--- build compiles a module: checked as the file "snippet", which the
--- checks name.
local function compiled(checks: boolean, file?: string): string
  local built = assert(teal.load(true))
  local env = assert(built.new_env({ defaults = {
    feat_lax = "off", gen_compat = "off", gen_target = "5.4", runtime_checks = checks,
  } }))
  local result = built.check_string(source, env, file or "snippet", "tl")
  local problems: {string} = {}
  for _, list in ipairs({ result.syntax_errors, result.type_errors }) do
    for _, each in ipairs(list) do
      problems[#problems + 1] = each.y .. ":" .. each.x .. ": " .. each.msg
    end
  end
  assert(#problems == 0, "the fixture does not compile: " .. table.concat(problems, "\n"))
  return (assert(built.generate(result.ast, "5.4", nil)))
end

local record Box
  name: string
  count: integer
  note?: string
end

local record Fixture
  call_greet: function(any)
  call_greet_again: function(any)
  dup: function(string, integer)
  call_times: function(any)
  call_note: function(any)
  call_box: function(any): any
  lookup: function({string:string}, string): string
  both: function(boolean): boolean, string
  maybe: function({string:string}, string): string | nil
  same: function<T>(T): T
  anything: function(any): any
  set_name: function(Box, any)
  set_count: function(Box, any)
  set_note: function(Box, any)
  new_box: function(): Box
  fail: function(): string
  relay: function(): string
  relay_lookup: function({string:string}, string): string
end

--- The fixture loaded with the checks and the hook installed, as the
--- chunk "snippet" so that a frame names `snippet:<line>`.
local function checked(file?: string): Fixture
  local code = compiled(true, file)
  worker.install_checks()
  local chunk = assert(load(code, "=snippet", "t"))
  return (chunk() as Fixture)
end

--- How many violations the hook has met, in all.
local function met(): integer
  local total = 0
  for _, violation in ipairs(worker.violations()) do total = total + violation.count end
  return total
end

--- The violations met while `fn` ran.
local function during(fn: function()): {worker.Violation}
  local before: {string:integer} = {}
  for _, violation in ipairs(worker.violations()) do
    before[violation.kind .. violation.at .. violation.target .. violation.actual] = violation.count
  end
  fn()
  local found: {worker.Violation} = {}
  for _, violation in ipairs(worker.violations()) do
    local key = violation.kind .. violation.at .. violation.target .. violation.actual
    if violation.count > (before[key] or 0) then found[#found + 1] = violation end
  end
  return found
end

--- A nil given a parameter of a type that does not admit it is reported
--- at the line of the call, not the function's; a value of the declared
--- kind, and a nil given an optional parameter, are not.
local function test_a_nil_parameter_is_reported_at_its_caller()
  local fixture = checked()
  local found = during(function() fixture.call_greet(nil) end)
  assert(#found == 2, #found .. " violations")
  assert(found[2].kind == "return" and found[2].actual == "nil", "the nil is returned on")
  found = { found[1] }
  assert(found[1].kind == "parameter" and found[1].declared == "string" and found[1].actual == "nil",
    found[1].declared .. " " .. found[1].actual)
  assert(found[1].at == "snippet:" .. line_of("greet(v as string, 1)"), found[1].at)
  assert(found[1].target:find("who", 1, true) and found[1].target:find("greet", 1, true),
    found[1].target)
  assert(#during(function() fixture.call_greet("fine") end) == 0)
  assert(#during(function() fixture.call_note(nil) end) == 0, "a nil for an optional parameter")
  assert(#during(function() fixture.call_note("note") end) == 0)
end

--- A number that is not an integer, a string for a table and a table for
--- a string are told by their kind; an integer given a number parameter
--- is not a violation, as every integer is a number.
local function test_a_wrong_kind_is_reported_by_its_kind()
  local fixture = checked()
  local float = during(function() fixture.call_times(1.5) end)
  assert(#float == 1 and float[1].declared == "integer" and float[1].actual == "float",
    #float .. " violations")
  assert(#during(function() fixture.call_times(3) end) == 0)
  local text = during(function() fixture.call_box("not a box") end)
  assert(#text == 1 and text[1].declared == "table" and text[1].actual == "string")
  assert(#during(function() fixture.call_box({ name = "a", count = 1 }) end) == 0)
  local table_given = during(function() fixture.call_greet({}) end)
  assert(#table_given == 2 and table_given[1].actual == "table" and table_given[1].kind == "parameter" and
      table_given[2].kind == "return" and table_given[2].declared == "string",
    "a table given a string parameter, and returned as the string it is declared")
end

--- A value returned that the declared type does not admit is reported at
--- the `return`, a nil among them, and a missing return value apart from
--- an explicit nil.
local function test_a_return_value_of_the_wrong_kind_is_reported_at_the_return()
  local fixture = checked()
  local nothing = during(function() fixture.lookup({}, "missing") end)
  assert(#nothing == 1 and nothing[1].kind == "return" and nothing[1].declared == "string" and
      nothing[1].actual == "nil", #nothing .. " violations")
  assert(nothing[1].at == "snippet:" .. line_of("return m[key]") and nothing[1].at ~= "?",
    nothing[1].at)
  assert(#during(function() fixture.lookup({ present = "here" }, "present") end) == 0)
  local absent = during(function() fixture.both(true) end)
  assert(#absent == 1 and absent[1].actual == "absent" and absent[1].target == "return value 2",
    #absent .. " violations")
  assert(#during(function() fixture.maybe({}, "missing") end) == 0,
    "a nil returned where the type admits it")
end

--- A write to a declared record field is checked against the field's
--- type; the optional field admits nil; a write to a field of a
--- record the function declared the table of is checked too.
local function test_a_field_write_of_the_wrong_kind_is_reported_at_the_write()
  local fixture = checked()
  local box = fixture.new_box()
  local name = during(function() fixture.set_name(box, nil) end)
  assert(#name == 1 and name[1].kind == "field" and name[1].target == "field Box.name" and
      name[1].declared == "string" and name[1].actual == "nil", #name .. " violations")
  assert(name[1].at == "snippet:" .. line_of("box.name = v as string"), name[1].at)
  assert(#during(function() fixture.set_name(box, "fine") end) == 0)
  local count = during(function() fixture.set_count(box, 2.5) end)
  assert(#count == 1 and count[1].declared == "integer" and count[1].actual == "float")
  assert(#during(function() fixture.set_count(box, 4) end) == 0)
  assert(#during(function() fixture.set_note(box, nil) end) == 0, "a nil for an optional field")
  assert(box.name == "fine" and box.count == 4, "the writes are made as they were")
end

--- `any` and a type variable have no kind to check, and the Lua of a
--- compile without the checks is the Lua of one with them, but for the
--- checks, on the lines it has always had.
local function test_what_has_no_kind_is_unchecked_and_the_lines_stay()
  local plain, with = compiled(false), compiled(true)
  assert(not plain:find("__cosmic_tc", 1, true), "an unchecked compile carries a check")
  assert(with:find("__cosmic_tc", 1, true))
  assert(not with:find("p;snippet:%d+;same;"), "a type variable was checked")
  assert(not with:find("p;snippet:%d+;anything;"), "`any` was checked")
  assert(with:find("\"r;snippet:%d+;table\""), "a record returned was not checked as a table")
  local function lines(text: string): {string}
    local out: {string} = {}
    for each in (text .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = each end
    return out
  end
  local before, after = lines(plain), lines(with)
  assert(#before == #after, "the checks moved a line: " .. #before .. " against " .. #after)
  local at = line_of("return m[key]")
  assert(before[at]:find("m[key]", 1, true) and after[at]:find("m[key]", 1, true) and
      after[at]:find("__cosmic_tc", 1, true), "the check is not on the line of its return")
end

--- A value that is the declared kind never counts, whatever the path it
--- takes: a run of correct calls meets no violation.
local function test_correct_values_are_never_reported()
  local fixture = checked()
  local box = fixture.new_box()
  local before = met()
  fixture.call_greet("a")
  fixture.call_times(7)
  fixture.call_note(nil)
  fixture.call_box(box)
  assert(fixture.lookup({ k = "v" }, "k") == "v")
  fixture.maybe({}, "k")
  assert(fixture.same(5) == 5 and fixture.same(nil) == nil)
  assert(fixture.anything(nil) == nil)
  fixture.set_name(box, "n")
  fixture.set_count(box, 3)
  fixture.set_note(box, nil)
  fixture.set_note(box, "s")
  assert(met() == before, "a correct call was reported: " .. tostring(met() - before))
end

--- A `return f(x)` is a tail call, which no check is written around: it
--- would add a frame, and an `error` in the callee that blames its caller
--- (level 2) would name the function that tail-called it instead of what
--- called that. The callee's own return is checked, once.
local function test_a_tail_call_stays_a_tail_call()
  local function message(fixture: Fixture): string
    local ok, trouble = pcall(fixture.relay)
    assert(not ok)
    return tostring(trouble)
  end
  local plain = load(compiled(false), "=snippet", "t")() as Fixture
  local fixture = checked()
  assert(message(fixture) == message(plain), message(fixture) .. " against " .. message(plain))
  local found = during(function()
    local ok = pcall(function(): string return fixture.lookup({}, "none") end)
    assert(ok)
  end)
  assert(#found == 1 and found[1].kind == "return", #found .. " violations")
  local relayed = during(function() fixture.relay_lookup({}, "none") end)
  assert(#relayed == 1, "a tail-called return checked twice: " .. #relayed)
end

--- The hook runs on the library as it loaded, not as a test left it: one
--- that wraps `string.match` or `table.concat` in a function of its own, to
--- count the string work of what it measures, would have the hook call
--- that wrapper, whose own checked parameters call the hook.
local function test_the_hook_does_not_call_a_library_a_test_replaced()
  local fixture = checked()
  local library = string as any as {string:any}
  local joined = table as any as {string:any}
  local saved = { library.match, library.gmatch, joined.concat }
  local function refuse(): string
    error("the hook called a replaced library function")
  end
  library.match, library.gmatch, joined.concat = refuse, refuse, refuse
  local ok, trouble = pcall(function()
    fixture.call_greet("fine")
    fixture.call_greet(nil)
  end)
  library.match, library.gmatch, joined.concat = saved[1], saved[2], saved[3]
  assert(ok, trouble)
end

--- A name a function binds twice holds the last value of it, which is
--- checked against its own type: the first `_: string` is not checked
--- against the integer given the second, and a violation of the second is
--- still found.
local function test_a_name_bound_twice_is_checked_by_its_last_binding()
  local fixture = checked()
  assert(#during(function() fixture.dup("a", 2) end) == 0, "the first `_` met the second's value")
  local found = during(function() (fixture.dup as function(string, any))("a", 1.5) end)
  assert(#found == 1 and found[1].declared == "integer" and found[1].actual == "float",
    #found .. " violations")
end

--- A parameter violation names its caller however often the boundary is
--- violated: the 26th from a place never seen still says where it was.
local function test_a_late_violation_still_names_its_caller()
  local fixture = checked()
  for _ = 1, 25 do fixture.call_greet(nil) end
  local late = during(function() fixture.call_greet_again(nil) end)
  local parameter: worker.Violation = nil
  for _, each in ipairs(late) do
    if each.kind == "parameter" then parameter = each end
  end
  assert(parameter ~= nil and parameter.at ~= "?", "no caller named")
  assert(parameter.at == "snippet:" .. tostring(line_of("function Mod.call_greet_again") + 1), parameter.at)
end

--- The worker keeps `most_kept` distinct violations; the rest are counted.
local function test_the_distinct_violations_kept_are_bounded()
  local fixture = checked()
  local kept = #worker.violations()
  local dropped = worker.dropped_violations()
  local limit = worker.most_kept
  worker.most_kept = kept + 1
  fixture.call_greet(nil)
  worker.most_kept = limit
  assert(#worker.violations() == kept + 1, "kept past the bound")
  assert(worker.dropped_violations() - dropped == 1,
    "dropped " .. (worker.dropped_violations() - dropped))
  local counted = met()
  worker.most_kept = kept + 1
  fixture.call_greet(nil)
  worker.most_kept = limit
  assert(met() - counted == 1, "a violation already kept stopped counting at the bound")
end

--- A file name with the characters that split a spec or a report line in
--- it is written so that none does, and the checks still name it.
local function test_a_file_name_that_would_split_a_spec_is_written_safely()
  local fixture = checked("a;b\nc\td.tl")
  local found = during(function() fixture.lookup({}, "none") end)
  assert(#found == 1 and found[1].at == "a%3Bb%0Ac%09d.tl:" .. tostring(line_of("return m[key]")), found[1].at)
  assert(not compiled(true, "a;b\nc.tl"):find("a;b", 1, true))
end

--- A spec that does not parse checks nothing and fails nothing: the
--- values pass as they came, and a field's first value alone.
local function test_a_malformed_spec_is_no_failure_of_the_test()
  checked()
  local before = met()
  local hook = (_G as {string:any}).__cosmic_tc as function(integer, string, any...): any...
  for _, spec in ipairs({ "p;snippet:1;f;no equals", "x;snippet:1", "" }) do
    local first, second = hook(2, spec, "a", "b")
    assert(first == "a" and second == "b", spec)
  end
  -- A field's spec that does not parse passes its first value alone.
  assert(select("#", hook(2, "fx;broken", 1, 2)) == 1)
  assert(met() == before, "a malformed spec was reported")
end
