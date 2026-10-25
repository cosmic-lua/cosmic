--- The rule behind every code the new checker emits, as one table of rows and as rows of the build database's `catalog`.
---
--- A code is emitted by the lexer, the parser, the scope builder, the generator ([`lang.syntax_codes`] holds the rows of
--- these four), the lowering of declarations ([`lang.declarations`]), the checker's expressions and flow ([`lang.check_codes`]) or the
--- warnings ([`lang.warnings`]). Each module lists its codes, and [`ErrorCatalog.problems`] says where a code has no
--- row, a row names no code, or a row leaves a part of the rule out.
---
--- [`ErrorCatalog.insert`] writes a row per code to the `catalog` table ([`build.schema`]) with the kind `code`, the module
--- that emits it as `module` and the code as `symbol`, so that `cosmic docs <code>` ([`build.docs`]) answers with the rule,
--- why the language holds it and the fix. The `message` is left NULL: the guidance of an uncaught run-time error
--- ([`cosmic.errors`]) matches that column alone, and a code's words are no message of a running program.
---
--- [`build.writer`] writes these rows into the projection after the extracted ones, for a compile with the new checker
--- (`COSMIC_GRAMMAR=new`, [`build.importer`]'s [`Result.catalog`]): its keys hold the code that reads, so the rows belong to
--- that compile.
--
-- TODO: write these rows into every projection and the shipped catalog, and delete the fork's extracted `catalog` rows,
-- once the new checker compiles the tool (doc/plans/strict-teal.md, "the switch").
local Codes = require("lang.check_codes")
local Codegen = require("lang.codegen")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local Sqlite = require("cosmic.sqlite")
local SyntaxCodes = require("lang.syntax_codes")
local Warnings = require("lang.warnings")
local bind = require("build.bind")
local plural = require("build.plural")

local record ErrorCatalog
  --- What emits a code.
  enum Stage
    "lexer"
    "parser"
    "scopes"
    "generator"
    "declarations"
    "checker"
    "warning"
  end

  --- A code and the rule behind it.
  record Row
    code: string
    stage: Stage
    --- `error`, or the kind of the warning (`unused`, `unread`, `hint`).
    kind: string
    rule: string
    why: string
    fix: string
    --- The module that emits the code, and the file of its row.
    module: string
    file: string
  end

  --- A code that can be emitted and the stage that finds it first.
  record Emitted
    code: string
    stage: Stage
  end

  --- Every code that can be emitted, in the order the stages run: the lexer's, the parser's own, the scope builder's, the
  --- declarations', the checker's and the warnings', and the generator's. A code a user sees in `(code)` is one of these;
  --- [`lang.relation`]'s `Code` names the reason inside a refusal's message and is no error code. A code two stages emit (`semicolon` of the lexer and the parser,
  --- `float_key` of the declarations and the checker) is listed once, under the first.
  emitted: function(): {Emitted}

  --- The rows of the codes that can be emitted, in the order of `emitted`; a code with no row has none here.
  rows: function(): {Row}

  --- What is wrong with `rows` as the rows of the codes `emitted`, one line each: a code with no row, a row for a code nothing
  --- emits, a code with two rows, and a row whose rule, why or fix is empty. Empty where all is well.
  check: function(emitted: {Emitted}, rows: {Row}): {string}

  --- [`ErrorCatalog.check`] of the codes the checker emits and the rows its catalogs hold.
  problems: function(): {string}

  --- The words of a row as `cosmic docs` shows them under its heading: what emits the code, then its rule, why and fix.
  text: function(row: Row): string

  --- Writes a row per code to the `catalog` table of `db` (of the attached schema `schema`, "" for the main one), in the
  --- order of `rows`, and answers how many it wrote. The index of `catalog_fts` is rebuilt by the caller
  --- ([`build.schema`]'s `rebuild`) once the table is filled.
  insert: function(db: Sqlite.Handle, schema: string): integer?, string
end

--- The module that emits the codes of a stage and the file that holds their rows.
local record Home
  module: string
  file: string
end

local function home_of(stage: ErrorCatalog.Stage): Home
  if stage == "lexer" then
    return { module = "lang.lexer", file = "lang/syntax_codes.tl" }
  elseif stage == "parser" then
    return { module = "lang.parser", file = "lang/syntax_codes.tl" }
  elseif stage == "scopes" then
    return { module = "lang.scopes", file = "lang/syntax_codes.tl" }
  elseif stage == "generator" then
    return { module = "lang.codegen", file = "lang/syntax_codes.tl" }
  elseif stage == "declarations" then
    return { module = "lang.declarations", file = "lang/declarations.tl" }
  elseif stage == "checker" then
    return { module = "lang.check", file = "lang/check_codes.tl" }
  end
  return { module = "lang.warnings", file = "lang/warnings.tl" }
end

--- What emits a code, as a row says it.
local function words_of(row: ErrorCatalog.Row): string
  if row.stage == "lexer" then
    return "lexer error"
  elseif row.stage == "parser" then
    return "syntax error"
  elseif row.stage == "scopes" then
    return "scope error"
  elseif row.stage == "generator" then
    return "generator refusal"
  elseif row.stage == "declarations" then
    return "declaration error"
  elseif row.stage == "checker" then
    return "type error"
  end
  return "warning (" .. row.kind .. ")"
end

--- The stage of a row of [`lang.syntax_codes`].
local function stage_of(stage: SyntaxCodes.Stage): ErrorCatalog.Stage
  if stage == "lexer" then
    return "lexer"
  elseif stage == "parser" then
    return "parser"
  elseif stage == "generator" then
    return "generator"
  end
  return "scopes"
end

function ErrorCatalog.emitted(): {ErrorCatalog.Emitted}
  local out: {ErrorCatalog.Emitted} = {}
  local seen: {string: boolean} = {}
  local function add(code: string, stage: ErrorCatalog.Stage)
    if seen[code] ~= true then
      seen[code] = true
      out[#out + 1] = { code = code, stage = stage }
    end
  end
  for _, code in ipairs(Lexer.codes) do add(code, "lexer") end
  for _, code in ipairs(Parser.codes) do add(code, "parser") end
  for _, code in ipairs(Scopes.codes) do add(code, "scopes") end
  for _, code in ipairs(Declarations.codes) do add(code, "declarations") end
  for _, code in ipairs(Codes.codes) do add(code, "checker") end
  for _, code in ipairs(Warnings.codes) do add(code, "warning") end
  for _, code in ipairs(Codegen.codes) do add(code, "generator") end
  return out
end

--- A row made of a catalog's.
local function row_of(code: string, stage: ErrorCatalog.Stage, kind: string, rule: string, why: string,
                      fix: string): ErrorCatalog.Row
  local home = home_of(stage)
  return {
    code = code, stage = stage, kind = kind, rule = rule, why = why, fix = fix, module = home.module, file = home.file,
  }
end

--- Every row of the four catalogs, with the stage its module emits it in.
local function all_rows(): {ErrorCatalog.Row}
  local out: mut {ErrorCatalog.Row} = {}
  for _, r in ipairs(SyntaxCodes.catalog) do
    out[#out + 1] = row_of(r.code, stage_of(r.stage), "error", r.rule, r.why, r.fix)
  end
  for _, r in ipairs(Declarations.catalog) do
    out[#out + 1] = row_of(tostring(r.code), "declarations", "error", r.rule, r.why, r.fix)
  end
  for _, r in ipairs(Codes.catalog) do
    out[#out + 1] = row_of(tostring(r.code), "checker", "error", r.rule, r.why, r.fix)
  end
  for _, r in ipairs(Warnings.catalog) do
    out[#out + 1] = row_of(tostring(r.code), "warning", tostring(r.kind), r.rule, r.why, r.fix)
  end
  return out
end

function ErrorCatalog.rows(): {ErrorCatalog.Row}
  local by_code: mut {string: ErrorCatalog.Row} = {}
  for _, r in ipairs(all_rows()) do
    if by_code[r.code] == nil then
      by_code[r.code] = r
    end
  end
  local out: mut {ErrorCatalog.Row} = {}
  for _, e in ipairs(ErrorCatalog.emitted()) do
    local r = by_code[e.code]
    if r ~= nil then
      out[#out + 1] = r
    end
  end
  return out
end

function ErrorCatalog.check(emitted: {ErrorCatalog.Emitted}, rows: {ErrorCatalog.Row}): {string}
  local out: mut {string} = {}
  local codes: mut {string: boolean} = {}
  for _, e in ipairs(emitted) do
    codes[e.code] = true
  end
  local counts: mut {string: integer} = {}
  for _, r in ipairs(rows) do
    counts[r.code] = (counts[r.code] or 0) + 1
    if codes[r.code] ~= true then
      out[#out + 1] = r.code .. " has a row in " .. r.file .. " and nothing emits it"
    end
    if r.rule == "" then
      out[#out + 1] = r.code .. " has an empty rule in " .. r.file
    end
    if r.why == "" then
      out[#out + 1] = r.code .. " has an empty why in " .. r.file
    end
    if r.fix == "" then
      out[#out + 1] = r.code .. " has an empty fix in " .. r.file
    end
  end
  for _, e in ipairs(emitted) do
    local count = counts[e.code] or 0
    if count == 0 then
      out[#out + 1] = e.code .. " is emitted by " .. e.stage .. " and has no row"
    elseif count > 1 then
      out[#out + 1] = e.code .. " has " .. plural.count(count, "row")
    end
  end
  return out
end

function ErrorCatalog.problems(): {string}
  return ErrorCatalog.check(ErrorCatalog.emitted(), all_rows())
end

function ErrorCatalog.text(row: ErrorCatalog.Row): string
  return words_of(row) .. " of " .. row.module .. "\nrule: " .. row.rule .. "\nwhy: " .. row.why .. "\nfix: " .. row.fix
end

function ErrorCatalog.insert(db: Sqlite.Handle, schema: string): integer?, string
  local count = 0
  for _, r in ipairs(ErrorCatalog.rows()) do
    local ok, why = Sqlite.run(db,
      "INSERT INTO " .. schema .. "catalog (kind, module, symbol, message, text, file, line) VALUES ('code', ?1, ?2, NULL, ?3, ?4, 0)",
      { bind.text(r.module), bind.text(r.code), bind.text(ErrorCatalog.text(r)), bind.text(r.file) })
    if not ok then
      return nil, r.code .. ": " .. why
    end
    count = count + 1
  end
  return count, ""
end

return ErrorCatalog
