--- What the tests of the readers that need the checker's types ([`build.syntax_receivers`], [`build.syntax_contracts`]) read
--- a program with: the program read by the new checker, with a small prelude of functions that fail and a stand-in
--- [`cosmic.log`]. The checker reads it against the real standard library's declarations. A test that uses this module
--- grants [`lang/prelude.d.tl`] and [`lang/stdlib.d.tl`] for reading.
local Rules = require("build.contract_rules")
local Fs = require("cosmic.fs")
local GenSyscalls = require("build.gen_syscalls")
local Programs = require("lang.check_programs")
local Receivers = require("build.syntax_receivers")
local Report = require("build.syntax_report")
local SyntaxContracts = require("build.syntax_contracts")
local Types = require("lang.types")

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

  --- The new checker's subject for a program: the tree, the names and the type report.
  subject: function(source: string, modules?: {string: string}): Report.Subject

  --- The new checker's reader of a program.
  port: function(source: string, modules?: {string: string}, given?: Rules.Exemptions): Said

  --- The functions the programs may call: `get` fails with a value, `put` with an effect, `name` cannot fail.
  PRELUDE: string

  --- A stand-in for [`cosmic.log`]: a `Logger` whose `say` and `complain` may stand alone.
  LOG: string
end

Fixture.PRELUDE = table.concat({
  "local function get(): integer?, string return nil, 'none' end",
  "local function put(): boolean, string return true, '' end",
  "local function name(): string return 'x' end",
  "local function pair(): boolean, integer return true, 1 end",
  "local function use(...: any) end",
  "local function complain(_v: integer?, _why: string) end",
  "local function lead(_a: string?, _b: string, _c?: integer) end",
  "local function maybe(_v: integer?, _why?: string) end",
  "local function sget(): string?, string return nil, 'none' end",
  "local record Note",
  "  note: function(Note, integer?, string)",
  "end",
  "local log: Note = { note = function(_: Note, _v: integer?, _why: string) end }",
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

--- A session of the new checker with its standard library lowered, and the modules it was given.
local record Session
  run: function(source: string, module?: string, modules?: {string: string}): Programs.Run
end

local sessions: mut {string: Session} = {}
local counter: mut {integer} = { 0 }
local standard: {string} = {}
local bindings: mut {string: string} = {}

function Fixture.subject(source: string, modules?: {string: string}): Report.Subject
  if standard[1] == nil then
    standard[1] = assert(Fs.read("lang/prelude.d.tl"))
    standard[2] = assert(Fs.read("lang/stdlib.d.tl"))
    -- The bindings of C are typed from the declarations the build derives from their headers, as the tree checks have them.
    for _, derivation in ipairs(GenSyscalls.targets) do
      local text = assert(GenSyscalls.declaration(assert(Fs.read(derivation.target.header)), derivation.target))
      bindings[derivation.path] = text
    end
  end
  -- A module the caller gives under the name of a binding stands in its place.
  local all: mut {string: string} = {}
  for module, text in pairs(bindings) do
    all[module] = text
  end
  for module, text in pairs(modules or {}) do
    all[module] = text
  end
  local names: mut {string} = {}
  for module in pairs(all) do
    names[#names + 1] = module
  end
  table.sort(names)
  local key: mut {string} = {}
  for _, module in ipairs(names) do
    key[#key + 1] = module .. "\n" .. all[module]
  end
  -- The modules of a session are lowered with the first program, and stay in its program.
  local kept = table.concat(key, "\0")
  local held = sessions[kept]
  local given_modules: {string: string} = all
  if held == nil then
    held = { run = Programs.session(standard[1], standard[2], {}) }
    sessions[kept] = held
  else
    given_modules = {}
  end
  counter[1] = counter[1] + 1
  local module = "t" .. tostring(counter[1])
  local run = held.run(source, module, given_modules)
  local types: mut {integer: Types.Type} = {}
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

function Fixture.port(source: string, modules?: {string: string}, given?: Rules.Exemptions): Fixture.Said
  local subject = Fixture.subject(source, modules)
  local uses: mut {Fixture.Use} = {}
  for _, r in ipairs(Receivers.references(subject)) do
    uses[#uses + 1] = { module = r.module, member = r.member, line = r.line }
  end
  local read = SyntaxContracts.check(subject, given)
  return { refs = uses, problems = read.problems, used = read.used, sites = read.sites }
end

return Fixture
