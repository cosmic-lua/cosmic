--- `cosmic docs <code>` answers a code of the new checker with its rule, why it holds and the fix, from the `catalog` rows
--- [`build.error_catalog`] writes, and finds one by the words of its rule. The database also holds the symbols the tree
--- documents, among them the enum member of each code ([`Codes.Code.not_assignable`]) that a query for the code names too.
local ErrorCatalog = require("build.error_catalog")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local docs = require("build.docs")
local schema = require("build.schema")

Test.policy{}

local function insert_symbol(db: Sqlite.Handle, module: string, symbol: string, kind: string)
  assert(Sqlite.run(db,
    "INSERT INTO docs (module, symbol, source_symbol, exported, kind, signature, text, file, line) " ..
      "VALUES (?1, ?2, ?2, 1, ?3, ?2, 'A symbol of the tree.', ?4, 7)",
    { { text = module }, { text = symbol }, { text = kind }, { text = module:gsub("%.", "/") .. ".tl" } }))
end

--- A shipped database whose catalog holds the rows of the codes when `with_codes`, and whose docs hold, when
--- `with_symbols`, the enum member of every code and a few other symbols that share a code's name.
local function database(with_codes: boolean, with_symbols?: boolean): Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    assert(db:exec(statement))
  end
  if with_codes then
    local count, trouble = ErrorCatalog.insert(db, "")
    assert(count ~= nil, trouble)
  end
  if with_symbols == true then
    for _, module in ipairs({ "lang.check_codes", "lang.parser", "build.ast.node" }) do
      assert(Sqlite.run(db,
        "INSERT INTO modules (path, file, kind, source_hash, key, source, bytecode, tests) " ..
          "VALUES (?1, ?2, 'module', '', '', '', '', '')", { { text = module }, { text = module:gsub("%.", "/") .. ".tl" } }))
    end
    for _, e in ipairs(ErrorCatalog.emitted()) do
      insert_symbol(db, "lang.check_codes", "Codes.Code." .. e.code, "value")
    end
    insert_symbol(db, "lang.parser", "Parser.unclosed", "function")
    insert_symbol(db, "build.ast.node", "Node.semicolon", "field")
  end
  for _, statement in ipairs(schema.rebuild("")) do
    assert(db:exec(statement))
  end
  return db
end

local function view(db: Sqlite.Handle): docs.View
  return (assert(docs.view({ db })))
end

--- The element `i` of `list`, which a test expects to be there.
local function entry_at(list: {docs.Entry}, i: integer): docs.Entry
  local found: docs.Entry? = nil
  for at, entry in ipairs(list) do
    if at == i then
      found = entry
    end
  end
  assert(found ~= nil, "no entry " .. tostring(i))
  return found
end

local function line_at(list: {string}, i: integer): string
  local found: string? = nil
  for at, line in ipairs(list) do
    if at == i then
      found = line
    end
  end
  assert(found ~= nil, "no line " .. tostring(i))
  return found
end

local function test_a_code_is_answered_with_its_rule_why_and_fix()
  local db = database(true)
  local found = assert(docs.lookup(view(db), "nil_not_allowed"))
  assert(found.exact and #found == 1 and found.named == 1)
  local entry = entry_at(found, 1)
  assert(entry.kind == "code" and entry.module == "lang.check" and entry.symbol == "nil_not_allowed")
  local lines = assert(docs.render(view(db), entry))
  assert(#lines == 5)
  assert(line_at(lines, 1) == "lang.check nil_not_allowed (lang/check_codes.tl)", line_at(lines, 1))
  assert(line_at(lines, 2) == "  type error of lang.check", line_at(lines, 2))
  assert(line_at(lines, 3) == "  rule: nil is its own type", line_at(lines, 3))
  assert(line_at(lines, 4):find("^  why: a type admits nil only as `T%?`") ~= nil, line_at(lines, 4))
  assert(line_at(lines, 5):find("^  fix: test it %(`if <value> == nil") ~= nil, line_at(lines, 5))
  db:close()
end

local function test_a_code_comes_before_the_symbols_that_share_its_name_on_a_database_that_holds_the_tree()
  local db = database(true, true)
  local v = view(db)
  -- every code, whatever symbols are named alike: the code's row first, the enum member still reachable
  for _, e in ipairs(ErrorCatalog.emitted()) do
    local found = assert(docs.lookup(v, e.code))
    assert(found.exact and found.named >= 2, e.code .. ": " .. tostring(found.named))
    local first = entry_at(found, 1)
    assert(first.kind == "code" and first.symbol == e.code, e.code .. " is answered with " .. first.kind .. " " .. first.symbol)
    local reachable = false
    for _, entry in ipairs(found) do
      reachable = reachable or entry.symbol == "Codes.Code." .. e.code
    end
    assert(reachable, e.code .. " hides its enum member")
  end
  -- names that are also a function and a field
  local unclosed = assert(docs.lookup(v, "unclosed"))
  assert(entry_at(unclosed, 1).kind == "code" and #unclosed == 3, tostring(#unclosed))
  local semicolon = assert(docs.lookup(v, "semicolon"))
  assert(entry_at(semicolon, 1).kind == "code" and #semicolon == 3, tostring(#semicolon))
  local answer = assert(docs.answer(v, { "not_assignable" }))
  assert(answer.found and line_at(answer.lines, 1) == "lang.check not_assignable (lang/check_codes.tl)", line_at(answer.lines, 1))
  db:close()
end

local function test_a_symbol_that_is_no_code_is_answered_as_before_on_a_database_that_holds_the_codes()
  local db = database(true, true)
  local found = assert(docs.lookup(view(db), "Parser.unclosed"))
  assert(found.exact and #found == 1 and entry_at(found, 1).kind == "function")
  db:close()
end

local function test_a_code_of_each_stage_is_answered_by_its_name()
  local db = database(true)
  local v = view(db)
  for _, code in ipairs({ "unterminated_string", "expected_token", "unknown_variable", "member_missing", "match_missing",
      "missing_return", "unused_function", "method_dot", "class_nested_refused" }) do
    local found = assert(docs.lookup(v, code))
    assert(found.exact and #found == 1 and entry_at(found, 1).symbol == code, code)
    local lines = assert(docs.render(v, entry_at(found, 1)))
    assert(#lines >= 5, code .. " has " .. tostring(#lines) .. " lines")
  end
  local answer = assert(docs.answer(v, { "duplicate_binding" }))
  assert(answer.found and line_at(answer.lines, 1):find("^lang%.parser duplicate_binding %(lang/syntax_codes%.tl%)") ~= nil,
    line_at(answer.lines, 1))
  db:close()
end

local function test_the_words_of_a_rule_find_the_codes_that_carry_them()
  local db = database(true)
  local found = assert(docs.lookup(view(db), "arrays are dense"))
  assert(not found.exact and #found >= 1)
  local names = ""
  for _, entry in ipairs(found) do
    assert(entry.kind == "code")
    names = names .. " " .. entry.symbol
  end
  assert(names:find("array_of_optional", 1, true) ~= nil, names)
  db:close()
end

local function test_a_database_without_the_rows_answers_a_code_with_nothing_as_it_did()
  local without = database(false)
  assert(#assert(docs.lookup(view(without), "nil_not_allowed")) == 0)
  assert(#assert(docs.lookup(view(without), "a type admits nil only")) == 0)
  without:close()
  -- a database built before the catalog had its index
  local old = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    if not statement:find("catalog_fts", 1, true) then
      assert(old:exec(statement))
    end
  end
  assert(#assert(docs.lookup(view(old), "nil_not_allowed")) == 0)
  old:close()
end
