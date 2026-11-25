--- [`build.docs_checks`] on small databases: each rule trips on a page with
--- the defect planted in it and passes the page without it.

local Array = require("cosmic.array")
local Sqlite = require("cosmic.sqlite")
local docs = require("build.docs")
local Doc = require("cosmic.doc")
local docs_checks = require("build.docs_checks")
local fixture = require("build.docs_fixture")
local schema = require("build.schema")
local symbols = require("cosmic.internal.symbols")

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
  mut signature: string
  mut text: string
  exported: boolean
end

--- A row for `symbol` of `module`.
local function row(module: string, symbol: string, kind: string, signature: string,
                   text: string): Row
  -- A member is written under the module's record: `Thing.add` is `add`.
  local member = if kind == "function" then "Thing." .. symbol else symbol end
  return { module = module, symbol = symbol, source_symbol = member, kind = kind,
    signature = signature, text = text, exported = true }
end

--- A projection holding `rows`, each module a row names among its
--- modules: what a public source reads, with nothing the writer's
--- analysis would add.
local function projection(rows: {Row}): schema.Build
  local db = assert(schema.hold(assert(Sqlite.memory())))
  local seen: mut {string: boolean} = {}
  for _, item in ipairs(rows) do
    if seen[item.module] ~= true then
      seen[item.module] = true
      assert(db:run(
        "INSERT INTO modules (path, file, kind, source_hash, key, source, bytecode, tests) " ..
          "VALUES (?1, ?2, 'module', '', '', '', '', '')",
        { { text = item.module }, { text = item.module:gsub("%.", "/") .. ".tl" } }))
    end
    assert(db:run(
      "INSERT INTO docs (module, symbol, source_symbol, exported, kind, signature, text, file, line) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1)",
      { { text = item.module }, { text = item.symbol }, { text = item.source_symbol },
        { integer = if item.exported then 1 else 0 end }, { text = item.kind },
        { text = item.signature }, { text = item.text },
        { text = item.module:gsub("%.", "/") .. ".tl" } }))
  end
  -- As cosmic's own projection records it: the library, by name.
  assert(db:exec("INSERT OR IGNORE INTO public_modules SELECT path FROM (SELECT path FROM modules UNION SELECT module FROM docs " ..
      "UNION SELECT module FROM uses UNION SELECT from_module FROM uses) WHERE " .. symbols.library_modules("path")))
  return db
end

-- Where `clean` puts the module's row and the row of `Thing.add`.
local MODULE <const> = 1
local ADD <const> = 3

--- A page that breaks no rule: a module, its record and a documented
--- function.
local function clean(): mut {Row}
  return {
    row("cosmic.thing", "", "module", "", "Things, made and counted."),
    row("cosmic.thing", "Thing", "record", "local record Thing", ""),
    row("cosmic.thing", "add", "function", "function Thing.add(a: integer): integer",
      "Adds one to `a`."),
  }
end

--- The lines `found` holds that mention `word`.
local function mentioning(found: {string}, word: string): {string}
  local out: mut {string} = {}
  for _, line in ipairs(found) do
    if line:find(word, 1, true) ~= nil then out[#out + 1] = line end
  end
  return out
end

--- A tree built by the writer's own analysis is held to the rules: an
--- undocumented function and field are named, an exemption with a
--- reason lets them stand, and one that no longer applies is stale.
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

--- Held to some files, as a narrowed `cosmic fix <paths>` holds it, the
--- check names what their modules miss and says nothing of the others':
--- neither an undocumented function nor an exemption gone stale.
local function test_held_to_some_files_it_judges_their_modules_alone(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/thing.tl"] = source(
      "--- Things.",
      "local record Thing",
      "end",
      "function Thing.bare(): integer",
      "  return 1",
      "end",
      "return Thing"),
    ["cosmic/other.tl"] = source(
      "--- Parts.",
      "local record Part",
      "end",
      "function Part.loose(): integer",
      "  return 1",
      "end",
      "return Part"),
  })
  local stale: docs_checks.Exempt = { surfaces = {}, undocumented = {
    ["cosmic.thing.Thing.gone"] = "removed", ["cosmic.other.Part.gone"] = "removed" } }
  local found = docs_checks.rendered(db, stale, { ["cosmic/other.tl"] = true })
  assert(#found == 2 and #mentioning(found, "cosmic.other.Part.loose: no doc comment") == 1 and
      #mentioning(found, "cosmic.other.Part.gone: excused") == 1, table.concat(found, "\n"))
  found = docs_checks.rendered(db, stale, { ["cosmic/thing.tl"] = true })
  assert(#found == 2 and #mentioning(found, "cosmic.thing.Thing.bare: no doc comment") == 1 and
      #mentioning(found, "cosmic.thing.Thing.gone: excused") == 1, table.concat(found, "\n"))
  found = docs_checks.rendered(db, stale, { ["cosmic/elsewhere.tl"] = true })
  assert(#found == 0, table.concat(found, "\n"))
  -- Over every file, it names all four.
  assert(#docs_checks.rendered(db, stale) == 4)
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
  table.insert(rows, row("cosmic.thing", "Pipe", "record", "local record Pipe", "A buffer."))
  local db = projection(rows)
  local found = docs_checks.rendered(db, none)
  assert(#found == 1 and found[1]:find("cosmic.thing.Pipe: a `local` record", 1, true) ~= nil,
    table.concat(found, "\n"))

  found = docs_checks.rendered(db, { undocumented = {}, surfaces = {
    ["cosmic.thing.Pipe"] = "a stand-in" } })
  assert(#found == 0, table.concat(found, "\n"))

  rows = clean()
  table.insert(rows, row("cosmic.thing", "Pipe", "record", "local record Pipe", "A buffer."))
  table.insert(rows, row("cosmic.thing", "drain", "function",
    "function Thing.drain(p: Pipe): integer", "Empties `p`."))
  found = docs_checks.rendered(projection(rows), none)
  assert(#found == 0, table.concat(found, "\n"))
end

--- A signature carrying a comment is refused, as is a page naming an
--- internal path; a location line and an example's source are not
--- prose.
local function test_a_comment_in_a_signature_and_an_internal_path_are_refused()
  local rows = clean()
  Array.at(rows, ADD).signature = "function Thing.add(a: integer): integer -- A tail call"
  local found = docs_checks.rendered(projection(rows), none)
  assert(#found == 1 and found[1]:find("the signature has a comment in it", 1, true) ~= nil,
    table.concat(found, "\n"))

  for _, path in ipairs({ "build/test.tl", "core/check.h", "cosmic/internal/http.tl" }) do
    rows = clean()
    Array.at(rows, ADD).text = "Adds one to `a`; " .. path .. " says how."
    found = docs_checks.rendered(projection(rows), none)
    -- The call's own page, and its module's, whose listing shows its
    -- first sentence.
    assert(#found == 2 and found[1]:find("names " .. path, 1, true) ~= nil and
        found[2]:find("names " .. path, 1, true) ~= nil,
      path .. ": " .. table.concat(found, "\n"))
  end

  -- A word that only ends like a directory is none.
  rows = clean()
  Array.at(rows, ADD).text = "Rebuild/score/coreboot are words; so is cosmic/fs.tl."
  found = docs_checks.rendered(projection(rows), none)
  assert(#found == 0, table.concat(found, "\n"))
end

--- A module the index lists must resolve under `cosmic docs <module>`.
local function test_a_module_the_index_lists_must_resolve()
  local db = projection(clean())
  assert(db:run(
    "INSERT INTO modules (path, file, kind, source_hash, key, source, bytecode, tests) " ..
      "VALUES ('cosmic.ghost', 'cosmic/ghost.tl', 'module', '', '', '', '', '')"))
  assert(db:exec("INSERT INTO public_modules (path) VALUES ('cosmic.ghost')"))
  local found = docs_checks.rendered(db, none)
  assert(#found >= 1 and #mentioning(found, "cosmic.ghost") >= 1, table.concat(found, "\n"))
end

--- What a page and a help text refer to must exist: a `cosmic docs`
--- query, a verb of `cosmic help`, and a `Module.symbol`.
local function test_a_dangling_reference_is_named()
  local rows = clean()
  Array.at(rows, MODULE).text = table.concat({
    "Things, made and counted. See `Thing.add` and `cosmic docs Thing.add`,",
    "`cosmic docs <module>` and `cosmic help <verb>`; not `Thing.gone`,",
    "`cosmic docs Thing.nothing` or `cosmic help nosuch`. `Other.name` is",
    "no module's. `cosmic docs cosmic` lists the library, and",
    "`cosmic docs Thing.add Thing.none` looks up each name, as",
    "`cosmic docs Thing.add cosmic.thing` does.",
  }, "\n")
  local db = projection(rows)
  local found = docs_checks.references(db, {}, { "test" }, {})
  assert(#found == 4, table.concat(found, "\n"))
  assert(#mentioning(found, "`cosmic docs Thing.add Thing.none` finds nothing") == 1,
    table.concat(found, "\n"))
  assert(#mentioning(found, "`Thing.gone` names no symbol") == 1, table.concat(found, "\n"))
  assert(#mentioning(found, "`cosmic docs Thing.nothing` finds nothing") == 1, table.concat(found, "\n"))
  assert(#mentioning(found, "`cosmic help nosuch` names no verb") == 1, table.concat(found, "\n"))

  found = docs_checks.references(db, {}, { "test" }, {
    ["Thing.gone"] = "kept", ["cosmic docs Thing.nothing"] = "kept", ["cosmic help nosuch"] = "kept",
    ["cosmic docs Thing.add Thing.none"] = "kept" })
  assert(#found == 0, table.concat(found, "\n"))
  found = docs_checks.references(db, {}, { "test" }, {
    ["Thing.gone"] = "kept", ["cosmic docs Thing.nothing"] = "kept", ["cosmic help nosuch"] = "kept",
    ["cosmic docs Thing.add Thing.none"] = "kept", ["Thing.add"] = "resolves now" })
  assert(#found == 1 and found[1]:find("`Thing.add` is allowed to dangle", 1, true) ~= nil,
    table.concat(found, "\n"))
end

--- A name `cosmic docs` reports as removed is still a stale reference: a
--- page that names it in a `cosmic docs` span is reported with what
--- replaces it.
local function test_a_page_naming_a_removed_symbol_is_stale()
  local db = projection({
    row("cosmic.net", "", "module", "",
      "Sockets. See `cosmic docs os.getenv`, and `Net.unix`."),
    row("cosmic.net", "Net", "record", "local record Net", ""),
    row("cosmic.net", "unix", "function", "function Net.unix(path: string): string",
      "A socket file's address."),
  })
  local found = docs_checks.references(db, {}, { "test" }, {})
  assert(#found == 1, table.concat(found, "\n"))
  assert(#mentioning(found, "`cosmic docs os.getenv` names a removed symbol: os.getenv is not available: " ..
      "use Env.get(name)") == 1,
    table.concat(found, "\n"))
end

--- A public page that names a module the library keeps to itself, by its
--- name or its file, or a symbol of one, sends its reader to a page
--- `cosmic docs` does not have: each is named. A module a closed directory
--- opens is no such thing.
local function test_a_reference_to_a_module_the_library_keeps_is_named()
  local rows = clean()
  Array.at(rows, MODULE).text = table.concat({
    "Things, made and counted. See `cosmic.thing.inner` and",
    "`cosmic/thing/inner.tl`, and `Inner.turn` there; `cosmic.thing.open`",
    "and `Open.wide` are a caller's.",
  }, "\n")
  table.insert(rows, row("cosmic.thing.inner", "", "module", "", "The workings."))
  rows[#rows + 1] = { module = "cosmic.thing.inner", symbol = "Inner.turn", source_symbol = "Inner.turn", kind = "function",
    signature = "function Inner.turn()", text = "Turns.", exported = true }
  table.insert(rows, row("cosmic.thing.open", "", "module", "", "The door."))
  rows[#rows + 1] = { module = "cosmic.thing.open", symbol = "Open.wide", source_symbol = "Open.wide", kind = "function",
    signature = "function Open.wide()", text = "Opens.", exported = true }
  local db = projection(rows)
  assert(db:exec("DELETE FROM public_modules WHERE path = 'cosmic.thing.inner'"))
  local found = docs_checks.references(db, {}, { "test" }, {})
  assert(#found == 3, table.concat(found, "\n"))
  assert(#mentioning(found, "`cosmic.thing.inner` names a module the library keeps to itself") == 1,
    table.concat(found, "\n"))
  assert(#mentioning(found, "`cosmic/thing/inner.tl` names a module the library keeps to itself") == 1,
    table.concat(found, "\n"))
  assert(#mentioning(found, "`Inner.turn` names no symbol") == 1, table.concat(found, "\n"))
end

--- A name the page's own module declares is that module's, though
--- another module's record has its head: `Inner.turn` on a page of
--- cosmic.thing, where cosmic.thing declares `Inner`, is not
--- cosmic.thing.inner's.
local function test_a_name_the_module_declares_is_its_own()
  local rows = clean()
  Array.at(rows, MODULE).text = "Things. `Inner.turn` turns a thing."
  rows[#rows + 1] = { module = "cosmic.thing", symbol = "Inner:turn", source_symbol = "Inner:turn", kind = "function",
    signature = "function turn(self)", text = "Turns a thing.", exported = false }
  table.insert(rows, row("cosmic.thing.inner", "", "module", "", "The workings."))
  local found = docs_checks.references(projection(rows), {}, { "test" }, {})
  assert(#found == 0, table.concat(found, "\n"))
  Array.at(rows, MODULE).text = "Things. `Inner.turn` turns a thing; `Inner.spin` does not."
  found = docs_checks.references(projection(rows), {}, { "test" }, {})
  assert(#found == 1 and #mentioning(found, "`Inner.spin` names no symbol") == 1, table.concat(found, "\n"))
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
--- each resolves as `Type.member`.
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
  local found = assert(Doc.lookup(view, "Thing.Handle"))
  local handle = found[1]
  assert(handle ~= nil, "Doc.lookup found no Thing.Handle")
  local lines = assert(Doc.render(view, handle))
  assert(table.concat(lines, "\n"):find("size: integer -- How big", 1, true) ~= nil,
    table.concat(lines, "\n"))
  local checked = docs_checks.rendered(db, none)
  assert(#checked == 0, table.concat(checked, "\n"))
end
