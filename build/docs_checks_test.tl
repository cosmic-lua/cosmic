--- `build.docs_checks` on small databases: each rule trips on a page with
--- the defect planted in it and passes the page without it.

local Sqlite = require("cosmic.sqlite")
local docs = require("build.docs")
local docs_checks = require("build.docs_checks")
local fixture = require("build.docs_fixture")
local schema = require("build.schema")

--- Lines as one source file's text.
local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- What the checks let stand when a test states none.
local none: docs_checks.Exempt = { undocumented = {}, surfaces = {} }

--- One row of `docs`, as the writer would leave it for a public module.
local record Row
  module: string
  symbol: string
  source_symbol: string
  kind: string
  signature: string
  text: string
  exported: boolean
end

--- A row for `symbol` of `module`.
local function row(module: string, symbol: string, kind: string, signature: string,
                   text: string): Row
  -- A member is written under the module's record: `Thing.add` is `add`.
  local member = kind == "function" and "Thing." .. symbol or symbol
  return { module = module, symbol = symbol, source_symbol = member, kind = kind,
    signature = signature, text = text, exported = true }
end

--- A projection holding `rows`, each module a row names among its
--- modules: what a public source reads, with nothing the writer's
--- analysis would add.
local function projection(rows: {Row}): Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    assert(db:exec(statement))
  end
  local seen: {string: boolean} = {}
  for _, item in ipairs(rows) do
    if not seen[item.module] then
      seen[item.module] = true
      assert(Sqlite.run(db,
        "INSERT INTO modules (path, file, kind, source_hash, key, source, bytecode, tests) " ..
        "VALUES (?1, ?2, 'module', '', '', '', '', '')",
        { { text = item.module }, { text = item.module:gsub("%.", "/") .. ".tl" } }))
    end
    assert(Sqlite.run(db,
      "INSERT INTO docs (module, symbol, source_symbol, exported, kind, signature, text, file, line) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1)",
      { { text = item.module }, { text = item.symbol }, { text = item.source_symbol },
        { integer = item.exported and 1 or 0 }, { text = item.kind },
        { text = item.signature }, { text = item.text },
        { text = item.module:gsub("%.", "/") .. ".tl" } }))
  end
  return db
end

--- A page that breaks no rule: a module, its record and a documented
--- function.
local function clean(): {Row}
  return {
    row("cosmic.thing", "", "module", "", "Things, made and counted."),
    row("cosmic.thing", "Thing", "record", "local record Thing", ""),
    row("cosmic.thing", "add", "function", "function Thing.add(a: integer): integer",
      "Adds one to `a`."),
  }
end

--- The lines `found` holds that mention `word`.
local function mentioning(found: {string}, word: string): {string}
  local out: {string} = {}
  for _, line in ipairs(found) do
    if line:find(word, 1, true) ~= nil then out[#out + 1] = line end
  end
  return out
end

--- A tree built by the writer's own analysis passes, and is held to the
--- rules it would break: an undocumented function and field are named,
--- an exemption with a reason lets them stand, and one that no longer
--- applies is stale.
local function test_a_missing_doc_comment_is_named_and_can_be_excused(dir: string)
  local files = {
    ["cosmic/thing.tl"] = source(
      "--- Things.",
      "local record Thing",
      "  --- A point.",
      "  record Point",
      "    --- Across.",
      "    x: integer",
      "    y: integer",
      "  end",
      "end",
      "--- Adds.",
      "function Thing.add(p: Thing.Point): integer",
      "  return p.x",
      "end",
      "function Thing.bare(): integer",
      "  return 1",
      "end",
      "return Thing"),
  }
  local db = fixture.database(dir, files)
  local found = docs_checks.rendered(db, none)
  assert(#found == 2, table.concat(found, "\n"))
  assert(#mentioning(found, "cosmic.thing.Thing.bare: no doc comment") == 1, table.concat(found, "\n"))
  assert(#mentioning(found, "cosmic.thing.Thing.Point.y: no doc comment") == 1, table.concat(found, "\n"))

  found = docs_checks.rendered(db, { surfaces = {}, undocumented = {
    ["cosmic.thing.Thing.bare"] = "a stand-in", ["cosmic.thing.Thing.Point.y"] = "the other axis" } })
  assert(#found == 0, table.concat(found, "\n"))

  found = docs_checks.rendered(db, { surfaces = {}, undocumented = {
    ["cosmic.thing.Thing.bare"] = "a stand-in", ["cosmic.thing.Thing.Point.y"] = "the other axis",
    ["cosmic.thing.Thing.add"] = "no longer needed" } })
  assert(#found == 1 and found[1]:find("cosmic.thing.Thing.add: excused", 1, true) ~= nil,
    table.concat(found, "\n"))
end

--- A member a module keeps to itself, and a `local` type only such a
--- member names, are not on the page.
local function test_what_a_module_keeps_to_itself_is_not_shown(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/thing.tl"] = source(
      "--- Things.",
      "local record Thing",
      "  --- A handle.",
      "  record Handle",
      "    --- Which.",
      "    place: integer",
      "    _cache: Cache",
      "  end",
      "end",
      "local record Cache",
      "  --- Entries.",
      "  entries: {string}",
      "end",
      "local record Wiring",
      "  --- Fields.",
      "  fd: integer",
      "end",
      "--- Opens.",
      "function Thing.open(): Thing.Handle",
      "  return {}",
      "end",
      "return Thing"),
  })
  local found = docs_checks.rendered(db, none)
  assert(#found == 0, table.concat(found, "\n"))
end

--- A `local` record that no public signature names is a record the
--- module keeps to itself, though it is marked exported.
local function test_a_local_record_nothing_names_is_refused()
  local rows = clean()
  rows[#rows + 1] = row("cosmic.thing", "Pipe", "record", "local record Pipe", "A buffer.")
  local db = projection(rows)
  local found = docs_checks.rendered(db, none)
  assert(#found == 1 and found[1]:find("cosmic.thing.Pipe: a `local` record", 1, true) ~= nil,
    table.concat(found, "\n"))

  found = docs_checks.rendered(db, { undocumented = {}, surfaces = {
    ["cosmic.thing.Pipe"] = "a stand-in" } })
  assert(#found == 0, table.concat(found, "\n"))

  rows = clean()
  rows[#rows + 1] = row("cosmic.thing", "Pipe", "record", "local record Pipe", "A buffer.")
  rows[#rows + 1] = row("cosmic.thing", "drain", "function",
    "function Thing.drain(p: Pipe): integer", "Empties `p`.")
  found = docs_checks.rendered(projection(rows), none)
  assert(#found == 0, table.concat(found, "\n"))
end

--- A signature carrying a comment is refused, as is a page naming an
--- internal path; a location line and an example's source are not
--- prose.
local function test_a_comment_in_a_signature_and_an_internal_path_are_refused()
  local rows = clean()
  rows[3].signature = "function Thing.add(a: integer): integer -- A tail call"
  local found = docs_checks.rendered(projection(rows), none)
  assert(#found == 1 and found[1]:find("the signature has a comment in it", 1, true) ~= nil,
    table.concat(found, "\n"))

  for _, path in ipairs({ "build/test.tl", "core/check.h", "cosmic/internal/http.tl" }) do
    rows = clean()
    rows[3].text = "Adds one to `a`; " .. path .. " says how."
    found = docs_checks.rendered(projection(rows), none)
    assert(#found == 1 and found[1]:find("names " .. path, 1, true) ~= nil,
      path .. ": " .. table.concat(found, "\n"))
  end

  -- A word that only ends like a directory is none.
  rows = clean()
  rows[3].text = "Rebuild/score/coreboot are words; so is cosmic/fs.tl."
  found = docs_checks.rendered(projection(rows), none)
  assert(#found == 0, table.concat(found, "\n"))
end

--- A module the index lists must answer `cosmic docs <module>`.
local function test_a_module_the_index_lists_must_resolve()
  local db = projection(clean())
  assert(Sqlite.run(db,
    "INSERT INTO modules (path, file, kind, source_hash, key, source, bytecode, tests) " ..
    "VALUES ('cosmic.ghost', 'cosmic/ghost.tl', 'module', '', '', '', '', '')"))
  local found = docs_checks.rendered(db, none)
  assert(#found >= 1 and #mentioning(found, "cosmic.ghost") >= 1, table.concat(found, "\n"))
end

--- What a page and a help text refer to must exist: a `cosmic docs`
--- query, a verb of `cosmic help`, and a `Module.symbol`.
local function test_a_dangling_reference_is_named()
  local rows = clean()
  rows[1].text = table.concat({
    "Things, made and counted. See `Thing.add` and `cosmic docs Thing.add`,",
    "`cosmic docs <module>` and `cosmic help <verb>`; not `Thing.gone`,",
    "`cosmic docs Thing.nothing` or `cosmic help nosuch`. `Other.name` is",
    "no module's.",
  }, "\n")
  local db = projection(rows)
  local found = docs_checks.references(db, {}, { "test" }, {})
  assert(#found == 3, table.concat(found, "\n"))
  assert(#mentioning(found, "`Thing.gone` names no symbol") == 1, table.concat(found, "\n"))
  assert(#mentioning(found, "`cosmic docs Thing.nothing` finds nothing") == 1, table.concat(found, "\n"))
  assert(#mentioning(found, "`cosmic help nosuch` names no verb") == 1, table.concat(found, "\n"))

  found = docs_checks.references(db, {}, { "test" }, {
    ["Thing.gone"] = "kept", ["cosmic docs Thing.nothing"] = "kept", ["cosmic help nosuch"] = "kept" })
  assert(#found == 0, table.concat(found, "\n"))
  found = docs_checks.references(db, {}, { "test" }, {
    ["Thing.gone"] = "kept", ["cosmic docs Thing.nothing"] = "kept", ["cosmic help nosuch"] = "kept",
    ["Thing.add"] = "resolves now" })
  assert(#found == 1 and found[1]:find("`Thing.add` is allowed to dangle", 1, true) ~= nil,
    table.concat(found, "\n"))
end

--- A help text is read as the module docs are, and reports under the
--- name of what prints it.
local function test_a_help_text_is_held_to_the_same_references()
  local db = projection(clean())
  local found = docs_checks.references(db, {
    [""] = "Try `cosmic help test` or `cosmic help exit`, then `cosmic docs cosmic.thing`.",
    test = "Then `cosmic docs Thing.missing`, `cosmic help` alone, or `cosmic help nothing`.",
  }, { "test" }, {})
  assert(#found == 2, table.concat(found, "\n"))
  assert(#mentioning(found, "`cosmic help test`: `cosmic docs Thing.missing` finds nothing") == 1,
    table.concat(found, "\n"))
  assert(#mentioning(found, "`cosmic help test`: `cosmic help nothing` names no verb") == 1,
    table.concat(found, "\n"))
end

--- A type standing for another module's lists that type's members, and
--- each answers as `Type.member`.
local function test_a_type_standing_for_another_lists_members_that_resolve(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/internal/thing.tl"] = source(
      "local record thing",
      "  --- A handle.",
      "  record Handle",
      "    --- How big.",
      "    size: integer",
      "    --- Closes it.",
      "    close: function(self: Handle): boolean",
      "  end",
      "end",
      "return thing"),
    ["cosmic/thing.tl"] = source(
      "--- Things.",
      "local raw_thing = require(\"cosmic.internal.thing\")",
      "local record Thing",
      "  type Handle = raw_thing.Handle",
      "end",
      "--- Opens.",
      "function Thing.open(): Thing.Handle",
      "  return {}",
      "end",
      "return Thing"),
  })
  local view = assert(docs.view({ db }, { true }))
  local found = assert(docs.lookup(view, "Thing.Handle"))
  local lines = assert(docs.render(view, found[1]))
  assert(table.concat(lines, "\n"):find("size: integer -- How big", 1, true) ~= nil,
    table.concat(lines, "\n"))
  local checked = docs_checks.rendered(db, none)
  assert(#checked == 0, table.concat(checked, "\n"))
end
