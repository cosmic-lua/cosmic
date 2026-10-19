--- The readers that need the new checker's types, read over a whole tree and set against what the fork's build has already
--- written for the same tree: [`build.syntax_receivers`] (the record-field uses of `typed_refs`), [`build.syntax_contracts`]
--- (the error-slot discipline) and the stub check ([`build.syntax_stub`]'s `difference`). The tree check `typed` of
--- [`build.tree_checks`] asks it for the answer of the port on each module ([`Typed.row`]) and for where that differs from
--- the fork's ([`Typed.compare`], [`Typed.used`]).
---
--- The fork's side is the working database ([`build.work`]): the compile of each module of the tree wrote its `typed_refs`
--- rows, and a build that refuses a module ([`build.contracts`], the stub check of [`build.compilation`]) leaves its compile
--- marked refused, so the database holds, for the tree as it stands, the uses the fork found, and whether it held each
--- module to the discipline and to its stub. Nothing of the fork's compiler runs here.
---
--- A module is compared in these dimensions, each in the order the rows come in, and a count of the rows each compared:
--- `typed refs` (the uses of a module, by line, module and member -- by module and member alone where the translation moved
--- the lines), `contracts` (a module the discipline holds: held on both sides), `contracts used` (the exemptions each side
--- needs, over the tree), `stub` (a standard-library module: its stub types it as its source) and `kind` (which modules the
--- discipline holds). A difference is a line that starts with the dimension's name.
--
-- TODO: run the port by hand over the modules the discipline holds whose translation does not parse ([`lang/ast.tl`], [`lang/types.tl`]
-- and one more, which [`tree_checks.typed`] leaves out with `[translated]`), once their `[translated]` pins reach 0: until then the
-- first run of the port on them is at the switch.
--
-- TODO: delete this module with the fork's [`build.receivers`] and [`build.contracts`] at the switch, when the build compiles
-- with the new checker and nothing is set against the fork (doc/plans/strict-teal.md, "the switch").
local Contracts = require("build.contracts")
local Driver = require("build.driver")
local Receivers = require("build.syntax_receivers")
local Report = require("build.syntax_report")
local Sqlite = require("cosmic.sqlite")
local Stub = require("build.syntax_stub")
local SyntaxContracts = require("build.syntax_contracts")

local record Typed
  --- What the port reads of one module through the checker's types.
  record Row
    --- Whether the discipline holds the module (by its file's name).
    applies: boolean
    refs: {Receivers.Reference}
    --- The breaches of the discipline, `file:line: ...` each; none for a module it does not hold.
    problems: {string}
    --- The exemptions the module's check found use for ([`SyntaxContracts.Result`]'s `used`).
    used: {string}
    --- How many places each rule judged, by rule.
    sites: {string: integer}
    --- How many calls the checker gave no function ([`SyntaxContracts.Result`]'s `untyped`), which no rule judged.
    untyped: integer
    --- The lines a use is not seen on, in the module's own text (the translation's, which is the source's where it moved no
    --- line): the checker reported an error there, or a value a field is read through is typed `invalid` there
    --- ([`Receivers.blind`]).
    error_lines: {integer}
    --- The places (`<line> <name>`) among those the fork found a use at where the port reads a field or a method of that name
    --- through a value of a known type ([`Receivers.known`]).
    known: {string}
    --- Whether its stub was judged (a standard-library module), and why it is not held to its source, "" where it is.
    judged: boolean
    stub: string
  end

  --- What the fork's build wrote of one module.
  record ForkFile
    --- The kind the importer staged it as: `module`, `main`, `test`, `example`.
    kind: string
    --- Whether the compile is marked refused: its contracts or its stub were not held, and a build that did not judge kept it.
    refused: boolean
    refs: {Receivers.Reference}
  end

  --- What the fork's build wrote of the tree, by file.
  record Fork
    files: {string: ForkFile}
  end

  --- What the comparison of one module, or of the tree, found.
  record Outcome
    differences: {string}
    --- How many of the differences a pin may cover: the uses the port finds and the fork loses. Every other is always told.
    pinnable: integer
    --- How many rows each dimension compared.
    counts: {string: integer}
  end

  --- The dimensions of an [`Outcome`]'s `counts`, in the order they are named.
  dimensions: {string}

  --- What the port reads of `subject`, a module checked with its types kept. `applies` says the discipline holds it.
  row: function(subject: Report.Subject, applies: boolean, error_lines: {integer}, wanted: {string: boolean}): Row

  --- Whether the stub of a file is judged: a module of the standard library (`cosmic.*`) of the tree, not a test, an example
  --- or a declaration file.
  judges_stub: function(file: string, module: string): boolean

  --- Why the stub `made` of a module is not held to its source, "" where it is. `source` is the module read from its source in
  --- `built`, `stubbed` a build that reads its stub instead of it ([`Driver.Build`], with the modules it requires as `built`
  --- has them), whose errors the stub may not add to.
  stub_verdict: function(made: Stub.Made, built: Driver.Build, source: Driver.Outcome, stubbed: Driver.Build): string

  --- `row` with its stub judged: `why` is why it is not held to its source, "" where it is.
  judged: function(row: Row, why: string): Row

  --- The rows of `row` as lists of text, for a memo, and the row they spell (nil where they spell none).
  encode: function(row: Row): {{string}}
  decode: function(rows: {{string}}): Row | nil

  --- What the working database `db` holds of the tree: the rows of `typed_refs`, and the kind and the refusal of each compile
  --- of the plan, by file; nil and why where it cannot be read.
  from_database: function(db: Sqlite.Handle): Fork | nil, string

  --- The dimensions of `file` where the port's `row` and the fork's rows differ. `moved` says the translation moved lines.
  compare: function(file: string, row: Row, fork: ForkFile, moved: function(): boolean): Outcome

  --- The exemptions each side needs over the whole tree: the fork's, every entry of the tables for a file the discipline
  --- holds (a build that holds the tree refuses a stale one), and the port's, as the rows found use for them.
  used: function(rows: {string: Row}, fork: Fork): Outcome
end

Typed.dimensions = { "typed refs", "contracts", "contracts used", "stub", "kind" }

function Typed.judges_stub(file: string, module: string): boolean
  return SyntaxContracts.kind_of(file) == "module" and module:sub(1, 7) == "cosmic."
end

function Typed.row(subject: Report.Subject, applies: boolean, error_lines: {integer}, wanted: {string: boolean}): Typed.Row
  local read: SyntaxContracts.Result = { problems = {}, used = {}, sites = {}, untyped = 0 }
  if applies then
    read = SyntaxContracts.check(subject)
  end
  return {
    applies = applies, refs = Receivers.references(subject), problems = read.problems, used = read.used, sites = read.sites, untyped = read.untyped,
    error_lines = error_lines, known = Receivers.known(subject, wanted), judged = false, stub = "",
  }
end

function Typed.stub_verdict(made: Stub.Made, built: Driver.Build, source: Driver.Outcome, stubbed: Driver.Build): string
  if not made.pruned then
    return "its stub keeps every statement, so a project's checker would read and load all of it: a standard-library " ..
      "module must end by returning a name whose last top-level declaration spells its type"
  end
  local module = source.module
  local result = stubbed:result(module, true)
  if result == nil then
    return "its stub is not a module"
  end
  -- The stub may not add a refusal to the source's: a code it is refused for more often than the source is.
  local had: {string: integer} = {}
  for _, e in ipairs(source.errors) do
    had[e.code] = (had[e.code] or 0) + 1
  end
  local has: {string: integer} = {}
  for _, e in ipairs(result.errors) do
    has[e.code] = (has[e.code] or 0) + 1
    -- A body the stub leaves out is a function that returns nothing, and code after the `error()` that stands for a body
    -- that never returns is unreachable: the stub is the declarations, and not the bodies the fork read none of either.
    if has[e.code] > (had[e.code] or 0) and e.code ~= "missing_return" and e.code ~= "unreachable" then
      return tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg .. " (" .. e.code .. ")"
    end
  end
  local different = Stub.difference(built.program, stubbed.program, module)
  if different ~= nil then
    return "the stub a project's checker reads in its place types it differently from its source: " .. different
  end
  return ""
end

function Typed.judged(row: Typed.Row, why: string): Typed.Row
  return {
    applies = row.applies, refs = row.refs, problems = row.problems, used = row.used, sites = row.sites, untyped = row.untyped,
    error_lines = row.error_lines, known = row.known, judged = true, stub = why,
  }
end

function Typed.encode(row: Typed.Row): {{string}}
  local out: {{string}} = { { "A", row.applies and "1" or "0" } }
  for _, r in ipairs(row.refs) do
    out[#out + 1] = { "R", r.module, r.member, tostring(r.line) }
  end
  for _, problem in ipairs(row.problems) do
    out[#out + 1] = { "P", problem }
  end
  for _, used in ipairs(row.used) do
    out[#out + 1] = { "U", used }
  end
  for _, rule in ipairs(SyntaxContracts.rules) do
    out[#out + 1] = { "S", rule, tostring(row.sites[rule] or 0) }
  end
  out[#out + 1] = { "T", tostring(row.untyped) }
  for _, line in ipairs(row.error_lines) do
    out[#out + 1] = { "E", tostring(line) }
  end
  for _, at in ipairs(row.known) do
    out[#out + 1] = { "K", at }
  end
  out[#out + 1] = { "H", row.judged and "1" or "0", row.stub }
  return out
end

function Typed.decode(rows: {{string}}): Typed.Row | nil
  local applies, judged, stub = false, false, ""
  local refs: {Receivers.Reference} = {}
  local problems: {string} = {}
  local used: {string} = {}
  local sites: {string: integer} = {}
  local error_lines: {integer} = {}
  local known: {string} = {}
  local untyped = 0
  local seen = false
  for _, fields in ipairs(rows) do
    local tag = fields[1]
    local n = math.tointeger(tonumber(fields[#fields]))
    if tag == "A" and #fields == 2 then
      applies = fields[2] == "1"
      seen = true
    elseif tag == "R" and #fields == 4 and n ~= nil then
      refs[#refs + 1] = { module = fields[2], member = fields[3], line = n }
    elseif tag == "P" and #fields == 2 then
      problems[#problems + 1] = fields[2]
    elseif tag == "U" and #fields == 2 then
      used[#used + 1] = fields[2]
    elseif tag == "S" and #fields == 3 and n ~= nil then
      sites[fields[2]] = n
    elseif tag == "E" and #fields == 2 and n ~= nil then
      error_lines[#error_lines + 1] = n
    elseif tag == "T" and #fields == 2 and n ~= nil then
      untyped = n
    elseif tag == "K" and #fields == 2 then
      known[#known + 1] = fields[2]
    elseif tag == "H" and #fields == 3 then
      judged = fields[2] == "1"
      stub = fields[3]
    else
      return nil
    end
  end
  if not seen then
    return nil
  end
  return {
    applies = applies, refs = refs, problems = problems, used = used, sites = sites, untyped = untyped,
    error_lines = error_lines, known = known, judged = judged, stub = stub,
  }
end

function Typed.from_database(db: Sqlite.Handle): Typed.Fork | nil, string
  local fork: Typed.Fork = { files = {} }
  local plan, trouble = Sqlite.text_rows(db,
    "SELECT i.file, i.kind, COALESCE((SELECT c.seen FROM compiled c WHERE c.key = p.key), 0) " ..
      "FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' ORDER BY i.file")
  if plan == nil then
    return nil, trouble
  end
  for _, row in ipairs(plan) do
    fork.files[row:text(1)] = { kind = row:text(2), refused = (tonumber(row:text(3)) or 0) < 0, refs = {} }
  end
  local refs, refs_trouble = Sqlite.text_rows(db,
    "SELECT i.file, r.module, r.member, r.line FROM plan p JOIN inputs i ON i.path = p.path AND i.kind <> 'decl' " ..
      "JOIN typed_refs r ON r.key = p.key ORDER BY i.file, r.ordinal")
  if refs == nil then
    return nil, refs_trouble
  end
  for _, row in ipairs(refs) do
    local file = fork.files[row:text(1)]
    if file ~= nil then
      file.refs[#file.refs + 1] = { module = row:text(2), member = row:text(3), line = math.tointeger(tonumber(row:text(4))) or 0 }
    end
  end
  return fork, ""
end

local function spelled(r: Receivers.Reference, lined: boolean): string
  if lined then
    return r.module .. " " .. r.member .. ":" .. tostring(r.line)
  end
  return r.module .. " " .. r.member
end

--- The first place two lists of words differ, for a message.
local function first_difference(a: {string}, b: {string}): string
  for i = 1, math.max(#a, #b) do
    if a[i] ~= b[i] then
      return "at " .. tostring(i) .. ": `" .. tostring(a[i]) .. "` against `" .. tostring(b[i]) .. "`"
    end
  end
  return ""
end

function Typed.compare(file: string, row: Typed.Row, fork: Typed.ForkFile, moved: function(): boolean): Typed.Outcome
  local out: Typed.Outcome = { differences = {}, pinnable = 0, counts = {} }
  local function differ(dimension: string, how: string)
    out.differences[#out.differences + 1] = dimension .. ": " .. how
  end
  local function counted(dimension: string, n: integer)
    out.counts[dimension] = (out.counts[dimension] or 0) + n
  end
  -- Which modules the discipline holds: the staging says it by kind, the port by the name of the file.
  counted("kind", 1)
  local holds = fork.kind == "module" or fork.kind == "main"
  if SyntaxContracts.kind_of(file) ~= fork.kind then
    differ("kind", "the build staged it as " .. fork.kind .. ", the port reads it as " .. SyntaxContracts.kind_of(file))
  end
  -- The uses, merged in order (both lists are sorted by line, module and member; by module and member alone where the
  -- translation moved the lines, and then compared as that sorted list). What is on one side alone is told, unless it is one of
  -- the differences the new checker makes on purpose, each counted apart:
  --   - a use on a line where a value a field is read through is typed `invalid`, or the checker reported an error: the use
  --     is not seen;
  --   - a use the fork sees at a position where the port finds the same name read through a value of another, known type: the
  --     fork keys the type of a value by the position it starts at, so a call's or a list's type can stand for the value;
  --   - a use only the port finds, on a line where the fork lost the same name to another record: the other half of that.
  local blind: {integer: boolean} = {}
  for _, line in ipairs(row.error_lines) do
    blind[line] = true
  end
  local known: {string: boolean} = {}
  for _, at in ipairs(row.known) do
    known[at] = true
  end
  local lined = true
  local function order(a: Receivers.Reference, b: Receivers.Reference): integer
    if lined and a.line ~= b.line then
      return a.line < b.line and -1 or 1
    elseif a.module ~= b.module then
      return a.module < b.module and -1 or 1
    elseif a.member ~= b.member then
      return a.member < b.member and -1 or 1
    end
    return 0
  end
  local function last_name(r: Receivers.Reference): string
    return r.member:match("([^.]+)$") or r.member
  end
  --- The uses on one side alone.
  local record Alone
    fork: {Receivers.Reference}
    port: {Receivers.Reference}
  end
  local function merged(): Alone
    local alone: Alone = { fork = {}, port = {} }
    local theirs, ours = fork.refs, row.refs
    if not lined then
      theirs, ours = {}, {}
      for _, r in ipairs(fork.refs) do
        theirs[#theirs + 1] = r
      end
      for _, r in ipairs(row.refs) do
        ours[#ours + 1] = r
      end
      table.sort(theirs, function(a: Receivers.Reference, b: Receivers.Reference): boolean
        return order(a, b) < 0
      end)
      table.sort(ours, function(a: Receivers.Reference, b: Receivers.Reference): boolean
        return order(a, b) < 0
      end)
    end
    local i, j = 1, 1
    while theirs[i] ~= nil or ours[j] ~= nil do
      local a, b = theirs[i], ours[j]
      local c = 0
      if a == nil then
        c = 1
      elseif b == nil then
        c = -1
      elseif b ~= nil then
        c = order(a, b)
      end
      if c == 0 then
        i, j = i + 1, j + 1
      elseif c < 0 and a ~= nil then
        alone.fork[#alone.fork + 1] = a
        i = i + 1
      elseif b ~= nil then
        alone.port[#alone.port + 1] = b
        j = j + 1
      end
    end
    return alone
  end
  local alone = merged()
  if (#alone.fork > 0 or #alone.port > 0) and moved() then
    lined = false
    alone = merged()
  end
  counted("typed refs", math.max(#row.refs, #fork.refs))
  -- A file whose lines moved has no line to say an error or a position by: its errors explain a use the port lacks.
  local function seen_at(r: Receivers.Reference): boolean
    return (lined and known[r.line .. " " .. last_name(r)] == true) or (not lined and #row.known > 0)
  end
  local lost: {Receivers.Reference} = {}
  for _, r in ipairs(alone.fork) do
    if (lined and blind[r.line] == true) or (not lined and #row.error_lines > 0) then
      counted("typed refs lost to an invalid value", 1)
    elseif seen_at(r) then
      counted("typed refs the fork keys by position", 1)
      lost[#lost + 1] = r
    else
      differ("typed refs", "the fork finds " .. spelled(r, lined) .. " and the port does not")
    end
  end
  -- A use the port finds is the other half of one the fork keyed by position when the fork lost the same name on its line.
  local taken: {string: integer} = {}
  local function place(r: Receivers.Reference): string
    if lined then
      return tostring(r.line) .. " " .. last_name(r)
    end
    return "0 " .. last_name(r)
  end
  for _, r in ipairs(lost) do
    local at = place(r)
    taken[at] = (taken[at] or 0) + 1
  end
  for _, r in ipairs(alone.port) do
    local at = place(r)
    if (taken[at] or 0) > 0 then
      taken[at] = taken[at] - 1
      counted("typed refs the fork keys by position", 1)
    else
      differ("typed refs", "the port finds " .. spelled(r, lined) .. " and the fork does not")
      out.pinnable = out.pinnable + 1
    end
  end
  -- The verdict: the fork's compile is refused for a breach of the discipline or for a stub; the port's rows say which.
  if holds then
    counted("contracts", 1)
  end
  if row.judged then
    counted("stub", 1)
  end
  local breached = row.applies and #row.problems > 0
  local unheld = row.judged and row.stub ~= ""
  if fork.refused and not breached and not unheld then
    differ(holds and "contracts" or "stub", "the fork refuses it and the port finds nothing to refuse")
  elseif not fork.refused and breached then
    differ("contracts", "the fork holds it and the port finds " .. tostring(#row.problems) .. ": " .. row.problems[1])
  elseif not fork.refused and unheld then
    differ("stub", "the fork holds it and the port finds: " .. row.stub)
  end
  if holds ~= row.applies then
    differ("contracts", "the fork " .. (holds and "holds" or "does not hold") .. " it to the discipline, the port " ..
        (row.applies and "does" or "does not"))
  end
  return out
end

function Typed.used(rows: {string: Typed.Row}, fork: Typed.Fork): Typed.Outcome
  local out: Typed.Outcome = { differences = {}, pinnable = 0, counts = {} }
  local own = Contracts.own_exemptions()
  local expected: {string} = {}
  local function need(name: string, table_of: {string: string})
    for key in pairs(table_of) do
      local file = key:match("^([^:]*):")
      local held: Typed.ForkFile | nil = nil
      if file ~= nil then
        held = fork.files[file]
      end
      if held ~= nil and (held.kind == "module" or held.kind == "main") then
        expected[#expected + 1] = name .. " " .. key
      end
    end
  end
  need("exempt", own.exempt)
  need("parsing", own.parsing)
  need("casts", own.casts)
  need("modes", own.modes)
  table.sort(expected)
  local found: {string} = {}
  for _, row in pairs(rows) do
    for _, used in ipairs(row.used) do
      found[#found + 1] = used
    end
  end
  table.sort(found)
  out.counts["contracts used"] = math.max(#expected, #found)
  if table.concat(expected, "\n") ~= table.concat(found, "\n") then
    out.differences[1] = "contracts used: the exemptions the fork needs, " .. tostring(#expected) .. ", against those the port does, " ..
      tostring(#found) .. ", " .. first_difference(expected, found)
  end
  return out
end

return Typed
