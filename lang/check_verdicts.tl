--- The verdict of the new checker on a program of the fork's grammar, as the switch's gate reads it
--- ([`doc/plans/strict-teal.md`], "the switch"): the program put in the new grammar ([`lang.translate`]), read, scoped,
--- lowered and checked against the standard library ([`lang.check_programs`]), and what refused it, if anything.
---
--- The verdict table is data: [`testdata/gate/verdicts.json`] holds one row for each program the fork's tests pin
--- ([`build/teal_test.tl`]) and each input of the checker corpora (`testdata/fuzz/checker-total`, `checker-sound`),
--- with what the fork said of it (frozen, since the fork goes at the switch) and what the new checker says. The rule
--- behind each difference is in [`testdata/gate/retired.json`] (the fork refuses and the new checker takes) and
--- [`testdata/gate/rules.json`] (a code of the lexer, the parser or the scope builder, which no catalog holds yet). The
--- gate is a query that finds a difference with no rule, which [`Verdicts.problems`] runs, and `cosmic sql` runs on the
--- files as well:
---
---     cosmic sql --from testdata/gate/verdicts.json --from retired=testdata/gate/retired.json \
---       "select id from verdicts where fork = 'refused' and new = 'accepted' and id not in (select id from retired)"
---
--- `bin/cosmic build/gate_record.tl` writes the table again.
local Codes = require("lang.check_codes")
local Declarations = require("lang.declarations")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Parser = require("lang.parser")
local Programs = require("lang.check_programs")
local Scopes = require("lang.scopes")
local Shape = require("cosmic.shape")
local Translate = require("lang.translate")

--- A row of the table.
local record RowData
  --- The head of the digest of `source`, which a corpus input is named by.
  id: string
  --- Where the program comes from, separated by `; `: the tests that pin it (`build/teal_test.tl <test>`) or the
  --- corpus file.
  origins: string
  source: string
  --- What the fork said: "refused" or "accepted".
  fork: string
  --- "syntax" where its parser refused, "type" where its checker did, "" where it accepted.
  fork_stage: string
  --- The fork's own code of each error, separated by spaces, each once.
  fork_codes: string
  --- What the new checker says: "refused" or "accepted" (a program with only `unchecked_*` errors is accepted).
  new: string
  new_stage: string
  --- The codes of [`Verdict.codes`], separated by spaces.
  new_codes: string
end

--- The rule behind a code of the lexer, the parser or the scope builder, which no catalog has a row for.
local record RuleData
  code: string
  rule: string
  why: string
end

--- A program the fork refuses and the new checker takes: the rule that makes it right to, by the code of that rule
--- (a code with a catalog row), and why.
local record RetiredData
  id: string
  code: string
  reason: string
  --- A program in the new grammar that differs from this one by what the rule is about, and that the new checker
  --- refuses with `twin_code`: the twin that shows the rule is held where the program is taken. It is of the form the
  --- program is about, so that a change of that form is seen.
  twin: string
  --- The code of the twin's refusal, one with a catalog row (the same as `code` where the rule refuses by it).
  twin_code: string
end

local record Verdicts
  type Row = RowData
  type Rule = RuleData
  type Retired = RetiredData

  --- What the new checker said of one program.
  record Verdict
    --- Whether it refused: some error that is not an `unchecked_*` (a form a later piece types, reported and not a rule).
    refused: boolean
    --- The first stage with an error: "" where there is none, "parse" (the lexer, the parser, and what the translator
    --- left), "scopes", "lower" (the declarations) or "check" (the bodies).
    stage: string
    --- The code of each error, in the order the stages report them, each once.
    codes: {string}
    --- The variables of type `invalid` in a program with no error, which nothing reported: none, or a hole.
    silent: {string}
  end

  --- The digest head a program is named by.
  id: function(source: string): string

  --- The stage that reports `code` when it comes from before the bodies were checked.
  early_stage: function(code: string): string

  --- Judges programs against the standard library, which it lowers once: `prelude` is the text of the fork's prelude,
  --- `stdlib` that of checker/stdlib.d.tl. Each program is a module of its own, and is put in the new grammar first
  --- unless the call says it is in it.
  judge: function(prelude: string, stdlib: string): function(source: string, new_grammar?: boolean): Verdict

  --- The rows in `text`, or what is wrong with it.
  read_rows: function(text: string): {Row} | nil, string

  --- The rules in `text`.
  read_rules: function(text: string): {Rule} | nil, string

  --- The retired programs in `text`.
  read_retired: function(text: string): {Retired} | nil, string

  --- The text of `rows`, one row to a line.
  write_rows: function(rows: {Row}): string

  --- The text of `list`, one entry to a line.
  write_list: function<T>(list: {T}): string

  --- `row` with what the new checker says, `verdict`.
  with_new: function(row: Row, verdict: Verdict): Row

  --- Where the gate is not met, one line each: a program the fork refuses that the new checker takes with no retired
  --- row (or whose row names no code with a catalog row), a program the new checker refuses with a code no rule is
  --- known for, a row that is not the digest of its source, a retired row for a program that is not one. With
  --- `judge`, a retired row whose twin the new checker does not refuse with its code is one too. Empty when the gate
  --- holds.
  problems: function(rows: {Row}, rules: {Rule}, retired: {Retired},
                     judge?: function(source: string, new_grammar?: boolean): Verdict): {string}
end

--- The codes with a row in a catalog: those of the checker's expressions and flow, and of the declarations.
--
-- TODO: read the rule of a code of the lexer, the parser and the scope builder from its row in [`lang.syntax_codes`] (which
-- build/error_catalog_test.tl holds to the same words), and delete testdata/gate/rules.json, once this gate reads a catalog
-- for every code.
local catalogued: {string: boolean} = {}
for _, code in ipairs(Codes.codes) do
  catalogued[code] = true
end
for _, code in ipairs(Declarations.codes) do
  catalogued[code] = true
end

local parser_codes: {string: boolean} = {}
for _, code in ipairs(Parser.codes) do
  parser_codes[code] = true
end

local scope_codes: {string: boolean} = {}
for _, code in ipairs(Scopes.codes) do
  scope_codes[code] = true
end

function Verdicts.id(source: string): string
  return Hash.hex_sha256(source):sub(1, 16)
end

function Verdicts.early_stage(code: string): string
  if parser_codes[code] == true then
    return "parse"
  end
  if scope_codes[code] == true then
    return "scopes"
  end
  return "lower"
end

--- What the stages said of a program: the first stage with an error that is not an `unchecked_*` is the stage.
local function verdict_of(run: Programs.Run): Verdicts.Verdict
  local codes: {string} = {}
  local seen: {string: boolean} = {}
  local stage = ""
  local function note(code: string, from: string): string
    if seen[code] ~= true then
      seen[code] = true
      codes[#codes + 1] = code
    end
    if stage == "" and not code:find("^unchecked_") then
      return from
    end
    return stage
  end
  for _, code in ipairs(run.before) do
    stage = note(code, Verdicts.early_stage(code))
  end
  for _, e in ipairs(run.errors) do
    stage = note(e.code, "check")
  end
  local silent: {string} = {}
  if #codes == 0 then
    for _, v in ipairs(run.scoped.list) do
      local t = run.result.vars[v.id]
      if t ~= nil and t == run.program.store.invalid then
        silent[#silent + 1] = v.name
      end
    end
  end
  return { refused = stage ~= "", stage = stage, codes = codes, silent = silent }
end

local record Counter
  count: integer
end

function Verdicts.judge(prelude: string, stdlib: string): function(source: string, new_grammar?: boolean): Verdicts.Verdict
  local check = Programs.session(prelude, stdlib)
  local made: Counter = { count = 0 }
  return function(source: string, new_grammar?: boolean): Verdicts.Verdict
    made.count = made.count + 1
    local module = "program" .. tostring(made.count)
    local text = source
    if new_grammar ~= true then
      text = Translate.translate(source, module .. ".tl").text
    end
    return verdict_of(check(text, module))
  end
end

function Verdicts.with_new(row: Verdicts.Row, verdict: Verdicts.Verdict): Verdicts.Row
  return {
    id = row.id, origins = row.origins, source = row.source, fork = row.fork, fork_stage = row.fork_stage,
    fork_codes = row.fork_codes, new = verdict.refused and "refused" or "accepted", new_stage = verdict.stage,
    new_codes = table.concat(verdict.codes, " "),
  }
end

-- The files ----------------------------------------------------------------------------------------------------------

local ROW <const>: Shape.Typed<RowData> = Shape.record_of("RowData")
local RULE <const>: Shape.Typed<RuleData> = Shape.record_of("RuleData")
local RETIRED <const>: Shape.Typed<RetiredData> = Shape.record_of("RetiredData")

function Verdicts.read_rows(text: string): {Verdicts.Row} | nil, string
  local decoded, trouble = Json.decode(text)
  if decoded == nil then
    return nil, trouble
  end
  local rows, why: {Verdicts.Row} | nil, string = Shape.into(decoded, Shape.list(ROW.spec))
  if rows == nil then
    return nil, why
  end
  return rows, ""
end

function Verdicts.read_rules(text: string): {Verdicts.Rule} | nil, string
  local decoded, trouble = Json.decode(text)
  if decoded == nil then
    return nil, trouble
  end
  local rules, why: {Verdicts.Rule} | nil, string = Shape.into(decoded, Shape.list(RULE.spec))
  if rules == nil then
    return nil, why
  end
  return rules, ""
end

function Verdicts.read_retired(text: string): {Verdicts.Retired} | nil, string
  local decoded, trouble = Json.decode(text)
  if decoded == nil then
    return nil, trouble
  end
  local retired, why: {Verdicts.Retired} | nil, string = Shape.into(decoded, Shape.list(RETIRED.spec))
  if retired == nil then
    return nil, why
  end
  return retired, ""
end

function Verdicts.write_list<T>(list: {T}): string
  local lines: {string} = {}
  for i, entry in ipairs(list) do
    lines[i] = "  " .. assert(Json.encode(entry))
  end
  return "[\n" .. table.concat(lines, ",\n") .. "\n]\n"
end

function Verdicts.write_rows(rows: {Verdicts.Row}): string
  return Verdicts.write_list(rows)
end

-- The gate -----------------------------------------------------------------------------------------------------------

local function words(text: string): {string}
  local out: {string} = {}
  for word in text:gmatch("%S+") do
    out[#out + 1] = word
  end
  return out
end

function Verdicts.problems(rows: {Verdicts.Row}, rules: {Verdicts.Rule}, retired: {Verdicts.Retired},
                           judge?: function(source: string, new_grammar?: boolean): Verdicts.Verdict): {string}
  local out: {string} = {}
  local by_id: {string: Verdicts.Row} = {}
  for _, row in ipairs(rows) do
    if by_id[row.id] ~= nil then
      out[#out + 1] = row.id .. " is in the table twice"
    end
    by_id[row.id] = row
    if Verdicts.id(row.source) ~= row.id then
      out[#out + 1] = row.id .. " is not the digest of its source"
    end
  end
  local ruled: {string: boolean} = {}
  for _, rule in ipairs(rules) do
    if rule.rule == "" or rule.why == "" then
      out[#out + 1] = "the rule of " .. rule.code .. " has no name or no reason"
    end
    if catalogued[rule.code] == true then
      out[#out + 1] = rule.code .. " has a catalog row, which rules.json must not shadow"
    end
    ruled[rule.code] = true
  end
  local listed: {string: Verdicts.Retired} = {}
  for _, entry in ipairs(retired) do
    if listed[entry.id] ~= nil then
      out[#out + 1] = entry.id .. " is retired twice"
    end
    listed[entry.id] = entry
  end
  for _, row in ipairs(rows) do
    local entry = listed[row.id]
    if row.fork == "refused" and row.new == "accepted" then
      if entry == nil then
        out[#out + 1] = row.id .. " (" .. row.origins .. "): the fork refuses it and the new checker takes it, with " ..
          "no rule in retired.json"
      end
    elseif entry ~= nil then
      out[#out + 1] = entry.id .. " is retired, and the fork does not refuse it or the new checker does"
    end
    if row.new == "refused" then
      for _, code in ipairs(words(row.new_codes)) do
        if catalogued[code] ~= true and ruled[code] ~= true then
          out[#out + 1] = row.id .. " (" .. row.origins .. "): refused with " .. code .. ", which has no rule"
        end
      end
    end
  end
  for _, entry in ipairs(retired) do
    if by_id[entry.id] == nil then
      out[#out + 1] = entry.id .. " is retired and is in no row"
    end
    if catalogued[entry.code] ~= true then
      out[#out + 1] = entry.id .. " is retired by " .. entry.code .. ", which has no catalog row"
    end
    if catalogued[entry.twin_code] ~= true then
      out[#out + 1] = entry.id .. " has a twin refused by " .. entry.twin_code .. ", which has no catalog row"
    end
    if entry.reason == "" then
      out[#out + 1] = entry.id .. " is retired with no reason"
    end
    if judge ~= nil then
      local twin = judge(entry.twin, true)
      local held = false
      for _, code in ipairs(twin.codes) do
        held = held or code == entry.twin_code
      end
      if not twin.refused or not held then
        out[#out + 1] = entry.id .. ": its twin is not refused with " .. entry.twin_code .. " but with " ..
          table.concat(twin.codes, " ")
      end
    end
  end
  return out
end

return Verdicts
