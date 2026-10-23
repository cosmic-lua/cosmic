--- What the tests of the readers that need the checker's types ([`build.syntax_receivers`], [`build.syntax_contracts`]) hold
--- them to: a program read by the fork's compiler and its reporter ([`build.receivers`], [`build.contracts`]) and the same
--- program translated and read by the new checker, the two answers side by side.
---
--- A program is in the fork's Teal, with a small prelude of functions that fail and a stand-in [`cosmic.log`]; the new
--- checker reads its translation ([`lang.translate`]) against the real standard library's declarations. A test that uses
--- this module grants [`lang/prelude.d.tl`] and [`lang/stdlib.d.tl`] for reading.
local Contracts = require("build.contracts")
local Fs = require("cosmic.fs")
local GenSyscalls = require("build.gen_syscalls")
local Programs = require("lang.check_programs")
local Receivers = require("build.syntax_receivers")
local Report = require("build.syntax_report")
local SyntaxContracts = require("build.syntax_contracts")
local Translate = require("lang.translate")
local Types = require("lang.types")
local ast = require("build.ast")
local receivers = require("build.receivers")
local teal = require("build.teal")
-- In the closure, so the store the worker is given carries the declaration the checker reads with [`Store.source`]
-- ([`teal.serve_standard`]).
local type _ = require("cosmic.internal.process")

local record Fixture
  --- A use of a record's field, as either reader gives it.
  record Use
    module: string
    member: string
    line: integer
  end

  --- What one reader says of a program.
  record Said
    refs: {Use}
    problems: {string}
    --- The exemptions it found use for (the new reader only).
    used: {string}
    --- How many places each rule judged (the new reader only).
    sites: {string: integer}
  end

  --- The fork's reader of `source`, with the `modules` (by name, in the fork's Teal) it may require. `given` is the
  --- exemptions to hold it to.
  fork: function(source: string, modules?: {string: string}, given?: Contracts.Exemptions): Said

  --- The new checker's subject for the same program, translated first: the tree, the names and the type report.
  subject: function(source: string, modules?: {string: string}): Report.Subject

  --- The new checker's reader of the same program; the fork's `source` is translated first.
  port: function(source: string, modules?: {string: string}, given?: Contracts.Exemptions): Said

  --- The functions the programs may call: `get` fails with a value, `put` with an effect, `name` cannot fail.
  PRELUDE: string

  --- A stand-in for [`cosmic.log`]: a `Logger` whose `say` and `complain` may stand alone.
  LOG: string
end

Fixture.PRELUDE = table.concat({
  "local function get(): integer | nil, string return nil, 'none' end",
  "local function put(): boolean, string return true, '' end",
  "local function name(): string return 'x' end",
  "local function pair(): boolean, integer return true, 1 end",
  "local function use(...: any) end",
  "local function complain(_v: integer | nil, _why: string) end",
  "local function lead(_a: string | nil, _b: string, _c?: integer) end",
  "local function maybe(_v: integer | nil, _why?: string) end",
  "local function sget(): string | nil, string return nil, 'none' end",
  "local record Note",
  "  note: function(Note, integer | nil, string)",
  "end",
  "local log: Note = { note = function(_: Note, _v: integer | nil, _why: string) end }",
}, "\n") .. "\n"

Fixture.LOG = table.concat({
  "local record Log",
  "  record Logger",
  "    say: function(Logger, string): boolean, string",
  "    flush: function(Logger): boolean, string",
  "  end",
  "end",
  "function Log.new(): Log.Logger",
  "  return {",
  "    say = function(_: Log.Logger, _line: string): boolean, string return true, '' end,",
  "    flush = function(_: Log.Logger): boolean, string return true, '' end,",
  "  }",
  "end",
  "return Log",
}, "\n")

local built = teal.lazy()

function Fixture.fork(source: string, modules?: {string: string}, given?: Contracts.Exemptions): Fixture.Said
  teal.serve_standard(built)
  local env = assert(built.new_env({ defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" } }))
  local names: {string} = {}
  for module in pairs(modules or {}) do
    names[#names + 1] = module
  end
  table.sort(names)
  for _, module in ipairs(names) do
    local code, loaded = built.gen((modules or {})[module], env, nil, "tl")
    assert(code ~= nil, "the module " .. module .. " did not compile")
    env.modules[module] = loaded.type
  end
  local state = receivers.install(env)
  local code, result = built.gen(source, env, nil, "tl")
  assert(code ~= nil and #result.type_errors == 0 and #result.syntax_errors == 0,
    result.type_errors[1] ~= nil and result.type_errors[1].msg or "did not compile")
  local checked = result.ast
  assert(checked is ast.Node, "the compiler answered no syntax tree")
  local problems = Contracts.check("x.tl", checked, state, Contracts.quiet_records(env), Contracts.binding_tables(env), given,
    result.type)
  local uses: {Fixture.Use} = {}
  for _, r in ipairs(receivers.references(state, env, checked)) do
    uses[#uses + 1] = { module = r.module, member = r.member, line = r.line }
  end
  return { refs = uses, problems = problems, used = {}, sites = {} }
end

--- A session of the new checker with its standard library lowered, and the modules it was given.
local record Session
  run: function(source: string, module?: string, modules?: {string: string}): Programs.Run
end

local sessions: {string: Session} = {}
local counter: {integer} = { 0 }
local standard: {string} = {}
local bindings: {string: string} = {}

function Fixture.subject(source: string, modules?: {string: string}): Report.Subject
  if standard[1] == nil then
    standard[1] = assert(Fs.read("lang/prelude.d.tl"))
    standard[2] = assert(Fs.read("lang/stdlib.d.tl"))
    -- The bindings of C are typed from the declarations the build derives from their headers, as the tree checks have them.
    for _, derivation in ipairs(GenSyscalls.targets) do
      local text = assert(GenSyscalls.declaration(assert(Fs.read(derivation.target.header)), derivation.target))
      bindings[derivation.path] = Translate.translate(text, derivation.path .. ".tl").text
    end
  end
  local all: {string: string} = {}
  for module, text in pairs(modules or {}) do
    all[module] = text
  end
  for module, text in pairs(bindings) do
    all[module] = text
  end
  local names: {string} = {}
  for module in pairs(all) do
    names[#names + 1] = module
  end
  table.sort(names)
  local translated: {string: string} = {}
  local key: {string} = {}
  for _, module in ipairs(names) do
    -- A binding of C is held translated: it is the same for every program, and translating each one for each was most
    -- of what reading a program cost.
    translated[module] = bindings[module] or Translate.translate(all[module], module .. ".tl").text
    key[#key + 1] = module .. "\n" .. translated[module]
  end
  -- The modules of a session are lowered with the first program, and stay in its program.
  local kept = table.concat(key, "\0")
  local held = sessions[kept]
  local given_modules: {string: string} = translated
  if held == nil then
    held = { run = Programs.session(standard[1], standard[2], {}) }
    sessions[kept] = held
  else
    given_modules = {}
  end
  counter[1] = counter[1] + 1
  local module = "t" .. tostring(counter[1])
  local run = held.run(Translate.translate(source, module .. ".tl").text, module, given_modules)
  local types: {integer: Types.Type} = {}
  for id, t in pairs(run.lowered.types) do
    types[id] = t
  end
  for id, t in pairs(run.result.types) do
    types[id] = t
  end
  return {
    file = "x.tl", program = run.program, chunk = run.chunk, scoped = run.scoped, lowered = run.lowered, types = types,
    callees = run.result.callees,
  }
end

function Fixture.port(source: string, modules?: {string: string}, given?: Contracts.Exemptions): Fixture.Said
  local subject = Fixture.subject(source, modules)
  local uses: {Fixture.Use} = {}
  for _, r in ipairs(Receivers.references(subject)) do
    uses[#uses + 1] = { module = r.module, member = r.member, line = r.line }
  end
  local read = SyntaxContracts.check(subject, given)
  return { refs = uses, problems = read.problems, used = read.used, sites = read.sites }
end

return Fixture
