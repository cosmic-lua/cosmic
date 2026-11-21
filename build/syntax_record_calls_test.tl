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
    "local record Box<T>",
    "  value: T",
    "end",
    "return { Server, Box, Rules }",
    "",
  }, "\n"),
}

local function test_required_answers_each_top_level_module_by_its_first_name()
  local build = build_of(PROJECT)
  local outcome = assert(build:result("main", false))
  local required = RecordCalls.required(outcome.chunk)
  assert(required["lib.rules"] == "Rules", "the first binding names the module, not the later `local type`")
end

--- The last name of the declaration `target` stands for.
local function declared(target: RecordCalls.Target): string
  local t = target.type
  assert(t.tag == "named", "a record's type is a named one")
  return assert(t.decl.names[#t.decl.names])
end

local function test_a_name_resolves_to_a_record_in_scope_or_inside_a_required_module()
  local build = build_of(PROJECT)
  local outcome = assert(build:result("main", false))
  local required = RecordCalls.required(outcome.chunk)
  local last = outcome.chunk.last
  local own = assert(RecordCalls.resolve_name(build, outcome, "Server", last, required))
  assert(own.spelled == "Server" and declared(own) == "Server")
  local inner = assert(RecordCalls.resolve_name(build, outcome, "Server.Port", last, required))
  assert(inner.spelled == "Server.Port" and declared(inner) == "Port", "the path below a record reaches the inner one")
  local theirs = assert(RecordCalls.resolve_name(build, outcome, "lib.rules.Grant", last, required))
  assert(theirs.spelled == "Rules.Grant" and declared(theirs) == "Grant",
    "a record of a required module is spelled through the module's alias")
end

local function test_a_record_declared_below_the_call_is_not_in_scope()
  local build = build_of(PROJECT)
  local outcome = assert(build:result("main", false))
  local required = RecordCalls.required(outcome.chunk)
  local early, why = RecordCalls.resolve_name(build, outcome, "Server", outcome.chunk.first, required)
  assert(early == nil and why:find("names no record declared above it", 1, true) ~= nil, why)
  assert(RecordCalls.visible(outcome, outcome.chunk.first)["Server"] == nil)
  assert(RecordCalls.visible(outcome, outcome.chunk.last)["Server"] == true)
end

local function test_a_generic_record_is_refused_by_its_kind()
  local build = build_of(PROJECT)
  local outcome = assert(build:result("main", false))
  local required = RecordCalls.required(outcome.chunk)
  local box, why = RecordCalls.resolve_name(build, outcome, "Box", outcome.chunk.last, required)
  assert(box == nil and why == "it is a generic record, not a record", why)
end

local function test_a_type_is_spelled_as_the_calling_module_names_it()
  local build = build_of(PROJECT)
  local outcome = assert(build:result("main", false))
  local required = RecordCalls.required(outcome.chunk)
  local last = outcome.chunk.last
  local server = assert(RecordCalls.resolve_name(build, outcome, "Server", last, required))
  local port = assert(RecordCalls.resolve_name(build, outcome, "Server.Port", last, required))
  local grant = assert(RecordCalls.resolve_name(build, outcome, "lib.rules.Grant", last, required))
  local st, pt, gt = server.type, port.type, grant.type
  assert(st.tag == "named" and pt.tag == "named" and gt.tag == "named")
  local aliases: mut {string: string} = {}
  for module, alias in pairs(required) do aliases[module] = alias end
  local namer: RecordCalls.Namer = {
    program = build.program, module = "main", aliases = aliases, visible = RecordCalls.visible(outcome, last),
    target = st.decl, spelled = "Server",
  }
  assert(RecordCalls.spelling(namer, st, st.decl) == "Server")
  assert(RecordCalls.spelling(namer, pt, pt.decl) == "Server.Port", "a type inside the target is spelled below it")
  assert(RecordCalls.spelling(namer, gt, gt.decl) == "Rules.Grant", "a required module's type goes through its alias")
  local unseen: RecordCalls.Namer = { ...namer, visible = {}, aliases = {} }
  assert(RecordCalls.spelling(unseen, gt, gt.decl) == nil, "a module the call's file does not require has no spelling")
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

local function test_splices_ordered_from_the_last_go_in_at_their_offsets()
  local splices: {RecordCalls.Splice} = { { at = 5, text = "<late>" }, { at = 2, text = "<early>" } }
  assert(RecordCalls.spliced("abcdefg", splices) == "ab<early>cde<late>fg")
  assert(RecordCalls.spliced("abc", {}) == "abc")
end
