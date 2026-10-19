--- Tests of [`build.error_catalog`]: every code the new checker emits has a row (rule, why, fix), no row names a code
--- nothing emits, and the rows are written to the `catalog` table as `cosmic docs <code>` reads them.
local ErrorCatalog = require("build.error_catalog")
local Errors = require("cosmic.errors")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local SyntaxCodes = require("lang.syntax_codes")
local Test = require("cosmic.test")
local Verdicts = require("lang.check_verdicts")
local schema = require("build.schema")

Test.policy{
  grants = {
    { path = "lang/lexer.tl", letters = "r" },
    { path = "lang/parser.tl", letters = "r" },
    { path = "lang/scopes.tl", letters = "r" },
    { path = "lang/declarations.tl", letters = "r" },
    { path = "lang/check_codes.tl", letters = "r" },
    { path = "lang/warnings.tl", letters = "r" },
    { path = "lang/codegen.tl", letters = "r" },
    { path = "testdata/gate/rules.json", letters = "r" },
  },
}

local function read(path: string): string
  return (assert(Fs.read(path)))
end

--- The codes the `enum Code` of the module at `path` lists, in order, read from its text: the quoted words between the
--- line that opens it and its closing `end`, less the comments.
local function enum_of(path: string): {string}
  local out: {string} = {}
  local inside = false
  for line in read(path):gmatch("[^\n]*") do
    if not inside then
      inside = line:match("^  enum Code%s*$") ~= nil
    elseif line:match("^  end%s*$") then
      return out
    else
      local code = line:gsub("%-%-.*$", "")
      for word in code:gmatch('"([%w_]+)"') do
        out[#out + 1] = word
      end
    end
  end
  error(path .. " has no `enum Code`")
end

local function joined(list: {string}): string
  return table.concat(list, " ")
end

--- The codes of `list` that `other` lacks.
local function missing_from(list: {string}, other: {string}): {string}
  local held: {string: boolean} = {}
  for _, code in ipairs(other) do
    held[code] = true
  end
  local out: {string} = {}
  for _, code in ipairs(list) do
    if held[code] ~= true then
      out[#out + 1] = code
    end
  end
  return out
end

local function strings(list: {string}): {string}
  local out: {string} = {}
  for _, code in ipairs(list) do
    out[#out + 1] = code
  end
  return out
end

local function emitted_codes(): {string}
  local out: {string} = {}
  for _, e in ipairs(ErrorCatalog.emitted()) do
    out[#out + 1] = e.code
  end
  return out
end

--- The row of `code` among the rows the catalogs hold.
local function row_of(code: string): ErrorCatalog.Row
  for _, row in ipairs(ErrorCatalog.rows()) do
    if row.code == code then
      return row
    end
  end
  error(code .. " has no row")
end

--- A module's list of codes, and the file whose `enum Code` it is read from.
local record Listed
  path: string
  listed: string
end

local function test_every_code_that_can_be_emitted_has_a_row_and_no_row_names_a_code_nothing_emits()
  local problems = ErrorCatalog.problems()
  assert(#problems == 0, joined(problems))
  local emitted = emitted_codes()
  local rows = ErrorCatalog.rows()
  assert(#rows == #emitted, tostring(#rows) .. " rows for " .. tostring(#emitted) .. " codes")
  for i, row in ipairs(rows) do
    assert(row.code == emitted[i], row.code .. " is out of order")
  end
end

local function test_the_codes_each_module_lists_are_the_codes_of_its_enum_so_that_no_code_is_emitted_unlisted()
  local Lexer = require("lang.lexer")
  local Parser = require("lang.parser")
  local Scopes = require("lang.scopes")
  local Declarations = require("lang.declarations")
  local Codes = require("lang.check_codes")
  local Warnings = require("lang.warnings")
  local Codegen = require("lang.codegen")
  local modules: {Listed} = {
    { path = "lang/lexer.tl", listed = joined(strings(Lexer.codes)) },
    { path = "lang/parser.tl", listed = joined(strings(Parser.codes)) },
    { path = "lang/scopes.tl", listed = joined(strings(Scopes.codes)) },
    { path = "lang/declarations.tl", listed = joined(strings(Declarations.codes)) },
    { path = "lang/check_codes.tl", listed = joined(strings(Codes.codes)) },
    { path = "lang/warnings.tl", listed = joined(strings(Warnings.codes)) },
    { path = "lang/codegen.tl", listed = joined(strings(Codegen.codes)) },
  }
  local emitted = emitted_codes()
  for _, m in ipairs(modules) do
    local enum = enum_of(m.path)
    assert(#enum > 0, m.path .. " lists no code")
    -- the order of the list is the order of the enum, and every code of the enum has a row
    assert(joined(enum) == m.listed, m.path .. ": the enum lists " .. joined(enum) .. " and the list " .. m.listed)
    local lacking = missing_from(enum, emitted)
    assert(#lacking == 0, m.path .. " emits " .. joined(lacking) .. ", which has no row")
  end
end

local function test_a_code_two_stages_emit_has_one_row_under_the_stage_that_finds_it_first()
  local seen: {string: boolean} = {}
  for _, row in ipairs(ErrorCatalog.rows()) do
    assert(seen[row.code] ~= true, row.code .. " has two rows")
    seen[row.code] = true
  end
  -- the parser carries the lexer's errors over; the checker reports three codes the lowering also reports
  assert(row_of("semicolon").stage == "lexer")
  assert(row_of("bad_escape").stage == "lexer")
  assert(row_of("float_key").stage == "declarations")
  assert(row_of("param_untyped").stage == "declarations")
  assert(row_of("array_of_optional").stage == "declarations")
  assert(row_of("not_assignable").stage == "checker" and row_of("not_assignable").module == "lang.check")
  assert(row_of("unknown_variable").stage == "scopes")
  assert(row_of("unused_variable").stage == "warning" and row_of("unused_variable").kind == "unused")
  assert(row_of("method_dot").kind == "hint")
  assert(row_of("reserved_word").stage == "parser")
  assert(row_of("class_nested_refused").stage == "generator" and row_of("class_nested_refused").module == "lang.codegen")
end

local function test_check_names_a_code_with_no_row_a_row_for_no_code_two_rows_and_a_part_left_out()
  local good = row_of("not_assignable")
  local other = row_of("arity")
  local one: ErrorCatalog.Emitted = { code = "not_assignable", stage = "checker" }
  local emitted: {ErrorCatalog.Emitted} = { one, { code = "arity", stage = "checker" } }
  assert(#ErrorCatalog.check(emitted, { good, other }) == 0)
  assert(joined(ErrorCatalog.check(emitted, { good })) == "arity is emitted by checker and has no row")
  assert(joined(ErrorCatalog.check({ one }, { good, other })) ==
      "arity has a row in lang/check_codes.tl and nothing emits it")
  assert(joined(ErrorCatalog.check(emitted, { good, other, good })) == "not_assignable has 2 rows")
  local bare: ErrorCatalog.Row = {
    code = "arity", stage = "checker", kind = "error", rule = "", why = "", fix = "", module = "lang.check", file = "f.tl",
  }
  assert(joined(ErrorCatalog.check(emitted, { good, bare })) ==
      "arity has an empty rule in f.tl arity has an empty why in f.tl arity has an empty fix in f.tl")
end

local function test_the_rows_of_the_syntax_codes_say_what_the_gate_says_of_the_same_codes()
  local rules, trouble = Verdicts.read_rules(read("testdata/gate/rules.json"))
  assert(rules ~= nil, trouble)
  local checked = 0
  for _, rule in ipairs(rules) do
    local row = SyntaxCodes.row(rule.code)
    assert(row ~= nil, rule.code .. " has a rule in testdata/gate/rules.json and no row")
    assert(row.rule == rule.rule, rule.code .. ": the rule is " .. row.rule .. " in the row and " .. rule.rule .. " there")
    assert(row.why == rule.why, rule.code .. ": the reason differs from testdata/gate/rules.json")
    checked = checked + 1
  end
  assert(checked >= 30, "checked " .. tostring(checked))
end

local function test_a_fix_closes_its_placeholders_and_a_row_ends_with_no_full_stop()
  for _, row in ipairs(ErrorCatalog.rows()) do
    -- a placeholder is `<word>` or `<two words>`, and a `<` that Teal writes (`<const>`, `<T>`) is closed too
    local opened = select(2, row.fix:gsub("<", ""))
    local closed = select(2, row.fix:gsub(">", ""))
    assert(opened == closed, row.code .. ": a placeholder of the fix is not closed: " .. row.fix)
    assert(row.fix:find("^%s") == nil and row.fix:find("%s$") == nil, row.code .. ": the fix has space at an end")
    assert(row.why:sub(-1) ~= "." and row.fix:sub(-1) ~= ".", row.code .. ": a row ends with a full stop")
  end
end

--- A database with the shipped tables, the rows of the catalog written to it and its indexes built.
local function written(): Sqlite.Handle, integer
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    assert(db:exec(statement))
  end
  local count, trouble = ErrorCatalog.insert(db, "")
  assert(count ~= nil, trouble)
  for _, statement in ipairs(schema.rebuild("")) do
    assert(db:exec(statement))
  end
  return db, count
end

--- The rows `sql` finds in `db`.
local function rows_of(db: Sqlite.Handle, sql: string): {Sqlite.Row}
  local rows, trouble = Sqlite.text_rows(db, sql)
  assert(rows ~= nil, trouble)
  return rows
end

--- The first row of `rows`, which a query is expected to have found.
local function first(rows: {Sqlite.Row}): Sqlite.Row
  for _, row in ipairs(rows) do
    return row
  end
  error("the query found no row")
end

local function test_a_row_per_code_is_written_to_the_catalog_with_its_rule_why_and_fix_as_the_text()
  local db, count = written()
  assert(count == #emitted_codes())
  local totals = first(rows_of(db, "SELECT count(*), count(DISTINCT symbol) FROM catalog WHERE kind = 'code'"))
  assert(totals:text(1) == tostring(count) and totals:text(2) == tostring(count))
  local one = first(rows_of(db,
    "SELECT module, symbol, message, text, file, line FROM catalog WHERE symbol = 'nil_not_allowed'"))
  assert(one:text(1) == "lang.check" and one:text(5) == "lang/check_codes.tl")
  -- the message is NULL, which the guidance of an uncaught error would otherwise match
  local messages = first(rows_of(db, "SELECT count(*) FROM catalog WHERE kind = 'code' AND message IS NOT NULL"))
  assert(messages:text(1) == "0", messages:text(1))
  local text = one:text(4)
  assert(text:find("^type error of lang.check\nrule: nil is its own type\nwhy: ") ~= nil, text)
  assert(text:find("\nfix: test it %(", 1) ~= nil, text)
  local warning = first(rows_of(db, "SELECT text FROM catalog WHERE symbol = 'unread'"))
  assert(warning:text(1):find("^warning %(unread%) of lang.warnings\nrule: names are used\n") ~= nil)
  local early = first(rows_of(db, "SELECT text FROM catalog WHERE symbol = 'shadows'"))
  assert(early:text(1):find("^scope error of lang.scopes\n") ~= nil)
  db:close()
end

local function test_the_words_of_a_rule_are_found_by_the_full_text_index()
  local db = written()
  local found = assert(Sqlite.text_rows(db,
    "SELECT c.symbol FROM catalog_fts JOIN catalog c ON c.id = catalog_fts.rowid " ..
      "WHERE catalog_fts MATCH '\"array\" \"dense\"' AND c.kind = 'code' ORDER BY c.symbol"))
  local symbols: {string} = {}
  for _, row in ipairs(found) do
    symbols[#symbols + 1] = row:text(1)
  end
  assert(joined(symbols):find("array_of_optional", 1, true) ~= nil, joined(symbols))
  db:close()
end

local function test_the_guidance_of_an_uncaught_error_is_never_a_code_row_whatever_words_the_message_shares()
  local db = written()
  -- the run-time guidance matches the `message` column alone, which a code row leaves NULL
  for _, message in ipairs({
      "nil is its own type: a value that may be nil is no operand",
      "the relation: a value stands where a type is wanted only if its type is below it",
      "unused variable scratch",
  }) do
    assert(Errors.guidance_in(db, message) == nil, message)
  end
  db:close()
end
