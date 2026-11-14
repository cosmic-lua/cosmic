--- [`build.syntax_record_calls`] by itself: what a resolver reads of a module's top level and of a call's name, and
--- how its splices go into a source. [`build.syntax_shape_specs`]'s tests hold the same parts through a whole resolve.
local Driver = require("build.driver")
local Array = require("cosmic.array")
local Programs = require("lang.check_programs")
local RecordCalls = require("build.syntax_record_calls")
local Test = require("cosmic.test")

Test.policy{}

--- A build of the project `files` (name to text), lowered at `main`.
local function build_of(files: {string: string}): Driver.Build
  local entries: mut {{string}} = {}
  for name, text in pairs(files) do
    entries[#entries + 1] = { name, text }
  end
  table.sort(entries, function(a: {string}, b: {string}): boolean
    -- Each entry is the `{ name, text }` pair pushed above.
    return Array.at(a, 1) < Array.at(b, 1)
  end)
  local index = Driver.index(entries, function(_file: string): boolean
    return false
  end)
  local build = Driver.new({
    globals = { Driver.declarations("std", "std.d.tl", Programs.library, {}) },
    adjust = nil, external = {}, types = false,
  })
  build:provide(Driver.files(index))
  build:lower({ "main" })
  return build
end

local PROJECT <const>: {string: string} = {
  ["lib/rules.tl"] = "local record Rules\n  record Grant\n    path: string\n  end\nend\nreturn Rules\n",
  ["main.tl"] = table.concat({
    'local Rules = require("lib.rules")',
    'local type Again = require("lib.rules")',
    "local record Server",
    "  record Port",
    "    number: integer",
    "  end",
    "  host: string",
    "end",
    "local function generic<T>(x: T): T return x end",
    "return { Server, generic, Rules }",
    "",
  }, "\n"),
}

local function test_required_answers_each_top_level_module_by_its_first_name()
  local build = build_of(PROJECT)
  local outcome = assert(build:result("main", false))
  local required = RecordCalls.required(outcome.chunk)
  assert(required["lib.rules"] == "Rules", "the first binding names the module, not the later `local type`")
end

local function test_a_name_resolves_to_a_record_above_the_call_or_inside_a_required_module()
  local build = build_of(PROJECT)
  local outcome = assert(build:result("main", false))
  local required = RecordCalls.required(outcome.chunk)
  local last = outcome.chunk.last
  local own = assert(RecordCalls.resolve_name(build, outcome, "Server", last, required))
  assert(own.spelled == "Server" and own.type.tag == "named")
  local inner = assert(RecordCalls.resolve_name(build, outcome, "Server.Port", last, required))
  assert(inner.spelled == "Server.Port")
  local theirs = assert(RecordCalls.resolve_name(build, outcome, "lib.rules.Grant", last, required))
  assert(theirs.spelled == "Rules.Grant", "a record of a required module is spelled through the module's alias")
end

local function test_a_name_that_reaches_nothing_says_why()
  local build = build_of(PROJECT)
  local outcome = assert(build:result("main", false))
  local required = RecordCalls.required(outcome.chunk)
  local last = outcome.chunk.last
  local missing, why = RecordCalls.resolve_name(build, outcome, "Nowhere", last, required)
  assert(missing == nil and why:find("names no record declared above it", 1, true) ~= nil, why)
  local field, no_field = RecordCalls.resolve_name(build, outcome, "Server.Absent", last, required)
  assert(field == nil and no_field == '"Server" has no field "Absent"', no_field)
  local theirs, no_record = RecordCalls.resolve_name(build, outcome, "lib.rules.Absent", last, required)
  assert(theirs == nil and no_record == 'module "lib.rules" declares no record "Absent"', no_record)
end

local function test_splices_go_in_from_the_last_so_that_no_offset_moves()
  local splices: {RecordCalls.Splice} = { { at = 5, text = "<late>" }, { at = 2, text = "<early>" } }
  assert(RecordCalls.spliced("abcdefg", splices) == "ab<early>cde<late>fg")
  assert(RecordCalls.spliced("abc", {}) == "abc")
end
