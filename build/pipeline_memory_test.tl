--- The memory of the new checker's pipeline ([`build.pipeline`]): what a build still holds after it has checked and written
--- a module is the declarations the next module reads, and not the module's tokens, syntax tree and scopes, which are most
--- of what a build holds while it is read. A tree of a thousand modules is checked in a few of them at a time.
local Ceilings = require("build.ceilings")
local Driver = require("build.driver")
local Pipeline = require("build.pipeline")
local Programs = require("lang.check_programs")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")
local type build_module = require("build.module")

Test.policy{}

--- The modules a case compiles one after another, each requiring the one before, and the functions in each. A module of this
--- size holds some seven hundred tokens, which a build that kept every tree would hold eight times over.
local MODULES <const> = 8
local FUNCTIONS <const> = 40

--- The most the heap may hold on to while the modules are compiled, in kilobytes. The declarations of eight modules are some
--- tens of kilobytes; their syntax is some megabytes.
local BUDGET <const> = 1000

--- The [`cosmic.shape`] of the cases that resolve a record: the calls of `record_of` are given what the build knows of the record.
local SHAPE <const>: {string: string} = {
  ["cosmic.shape"] = table.concat({
    "local record Shape",
    "  record_of: function(string, ...: any): any",
    "  record: function(any): any",
    "  integer: any",
    "end",
    "return Shape",
    "",
  }, "\n"),
}

local function options(): Pipeline.Options
  return {
    globals = {
      sources = { Driver.declarations("std", "std.d.tl", Programs.library, false, {}) },
      adjust = function(_globals: {string: Scopes.Global}) end,
    },
    ceilings = assert(Ceilings.parse("")), types = true, standard = Driver.stubs(SHAPE), project = nil,
  }
end

--- The text of the module `i`: a record, its functions, and a value of the record that calls each and reads the module before.
--- With `shaped` it asks for the record's spec of [`cosmic.shape`], whose call the build resolves in a text of its own.
local function text_of(i: integer, shaped: boolean): string
  local lines: mut {string} = {}
  if shaped then
    lines[#lines + 1] = "local Shape = require(\"cosmic.shape\")"
  end
  if i > 1 then
    lines[#lines + 1] = ("local Prev = require(\"m_%d\")"):format(i - 1)
  end
  lines[#lines + 1] = "local record Box"
  lines[#lines + 1] = "  n: integer"
  lines[#lines + 1] = "end"
  local calls: mut {string} = {}
  for f = 1, FUNCTIONS do
    lines[#lines + 1] = ("local function f%d(a: integer): integer"):format(f)
    lines[#lines + 1] = ("  local b: integer = a + %d"):format(f)
    lines[#lines + 1] = "  return b * 2"
    lines[#lines + 1] = "end"
    calls[#calls + 1] = ("f%d(%d)"):format(f, f)
  end
  local total = table.concat(calls, " + ")
  if i > 1 then
    total = total .. " + Prev.n"
  end
  lines[#lines + 1] = "local total: integer = " .. total
  lines[#lines + 1] = "local box: Box = { n = total }"
  if shaped then
    lines[#lines + 1] = "local witness = Shape.record_of(\"Box\")"
    lines[#lines + 1] = "if witness == nil then"
    lines[#lines + 1] = "  box.n = 0"
    lines[#lines + 1] = "end"
  end
  lines[#lines + 1] = "return box"
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

local function module_of(i: integer): build_module.Plan
  local path = ("m_%d"):format(i)
  return {
    path = path, file = path .. ".tl", kind = "module", source = "", source_hash = "", requires = {},
    tests = {}, inputs = nil, has_top_level_return = true, generated = false, key = "", graph_key = "", lua = "",
  }
end

--- The most the heap held on to, over the baseline before the first module, while `MODULES` were compiled in the order they
--- require one another. It is counted after a full collection that follows each module, so it is what the build holds and not
--- the garbage of the module being compiled. With `keep` every syntax tree is held by the case, as a build that never let go
--- would.
local function held_while_compiling(keep: boolean, shaped: boolean): number
  local entries: mut {{string}} = {}
  local kinds: mut {string: string} = {}
  for i = 0, MODULES do
    local file = ("m_%d.tl"):format(i)
    entries[#entries + 1] = { file, text_of(i, shaped) }
    kinds[file] = "module"
  end
  local pipeline = Pipeline.over(entries, kinds, options())
  -- The first module pays for the library's declarations, which every build holds.
  local first, why = Pipeline.generate(module_of(0), pipeline)
  assert(first ~= nil, tostring(why))
  local held: mut {Driver.Outcome} = {}
  collectgarbage("collect")
  collectgarbage("collect")
  local base = collectgarbage("count")
  local worst = 0.0
  for i = 1, MODULES do
    if keep then
      held[#held + 1] = assert(pipeline.build:parsed(("m_%d"):format(i)))
    end
    local made, trouble = Pipeline.generate(module_of(i), pipeline)
    assert(made ~= nil, tostring(trouble))
    assert(not shaped or made.lua:find("record_of(\"Box\", ", 1, true) ~= nil, "the call is resolved: " .. made.lua)
    collectgarbage("collect")
    collectgarbage("collect")
    worst = math.max(worst, collectgarbage("count") - base)
  end
  local expected = 0
  if keep then
    expected = MODULES
  end
  assert(#held == expected)
  return worst
end

local function test_a_build_holds_the_declarations_of_the_modules_it_checked_and_not_their_syntax()
  local worst = held_while_compiling(false, false)
  assert(worst < BUDGET, ("the pipeline held %.0f KB after %d modules, over the budget of %d KB"):format(worst, MODULES, BUDGET))
end

local function test_a_build_that_kept_every_syntax_tree_is_over_the_budget()
  -- The budget is a bound with something on the other side of it: the same compile, with every tree kept, is far over it.
  local worst = held_while_compiling(true, false)
  assert(worst > 2 * BUDGET, ("keeping every tree held only %.0f KB, which the budget of %d KB cannot tell from none"):format(worst, BUDGET))
end

local function test_a_build_that_resolves_a_record_in_each_module_holds_no_more_of_their_syntax()
  -- The resolution reads the module in a build of its own: this build never meets the module before its text is replaced, so
  -- the modules it requires are not lowered and read again, and kept, for each module that asks for a record.
  local worst = held_while_compiling(false, true)
  assert(worst < BUDGET, ("the pipeline held %.0f KB after %d modules that resolve a record, over the budget of %d KB"):
      format(worst, MODULES, BUDGET))
end
