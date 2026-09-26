--- Every name `cosmic docs <name>` resolves to a doc anchor answers
--- with that one anchor (doc/design.md, principle 8). A bare name
--- matches every symbol ending in it -- `cosmic docs read` lists each
--- `X.read`, by design -- so a real member that shares an anchor's name
--- (`Proc.Relaunch.argv` beside `Entrypoint.argv`) is listed beside it
--- as any two members are. What is refused is two anchors sharing one:
--- a reader asking for the verb `test` was also shown the layout rule
--- for test files.
---
--- A doc anchor is a record of a public `cosmic/` module that exists to
--- be looked up, not passed around: every field of it is a documented
--- `string` (`test: string` in `cosmic.cli`'s `Cli`), and no function
--- or method in the public catalog takes or returns it. `cosmic.shape`'s
--- `Failure` has only strings too, but `failures` hands it out, so its
--- fields are an API's, not anchors.
---
--- It is a whole-tree question, asked of the shipped database
--- `o/cosmic.db`, as build/exports_test.tl asks its own.

local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local fixture = require("build.docs_fixture")
local symbols = require("build.symbols")

--- A whole-tree question, asked of the projection itself.
Test.needs{ store = true }

--- One row of the public catalog, as read here.
local record Row
  module: string
  symbol: string
  kind: string
  signature: string
  text: string
  file: string
  line: string
end

--- Whether `signature` names the type `name` as a whole word.
local function mentions(signature: string, name: string): boolean
  return signature:find("%f[%w_]" .. name .. "%f[^%w_]") ~= nil
end

--- Every pair of doc anchors in `db` that share a bare name, as
--- `<file>:<line>: <module> <symbol> and <module> <symbol>: ...`,
--- sorted, and every anchor record found, as `<module> <record>`.
local function colliding(db: Sqlite.Handle): {string}, {string: boolean}
  local rows = assert(Sqlite.text_rows(db,
    "SELECT module, symbol, kind, signature, text, file, line FROM docs WHERE " ..
    symbols.public_only("module", true) .. " ORDER BY module, id"))
  local all: {Row} = {}
  for _, r in ipairs(rows) do
    all[#all + 1] = { module = r[1], symbol = r[2], kind = r[3], signature = r[4],
      text = r[5], file = r[6], line = r[7] }
  end
  -- What takes or returns a value: a function, a method, or a field
  -- whose type is a function.
  local callable: {string} = {}
  for _, r in ipairs(all) do
    if r.kind == "function" or r.kind == "method"
        or (r.kind == "field" and r.signature:find("function", 1, true) ~= nil) then
      callable[#callable + 1] = r.signature
    end
  end
  local by_name: {string: {Row}} = {}
  local anchors: {string: boolean} = {}
  for _, owner in ipairs(all) do
    if owner.kind == "record" then
      local prefix = owner.symbol .. "."
      local fields: {Row} = {}
      local anchor = true
      for _, r in ipairs(all) do
        if r.module == owner.module and r.symbol:sub(1, #prefix) == prefix
            and r.symbol:find(".", #prefix + 1, true) == nil then
          local name = r.symbol:sub(#prefix + 1)
          fields[#fields + 1] = r
          if r.kind ~= "field" or r.signature ~= name .. ": string" or r.text == "" then
            anchor = false
          end
        end
      end
      for _, signature in ipairs(callable) do
        if mentions(signature, owner.symbol) then anchor = false end
      end
      if anchor then
        anchors[owner.module .. " " .. owner.symbol] = true
        for _, r in ipairs(fields) do
          local name = r.symbol:sub(#prefix + 1)
          local list = by_name[name] or {}
          list[#list + 1] = r
          by_name[name] = list
        end
      end
    end
  end
  local out: {string} = {}
  for name, list in pairs(by_name) do
    for i = 2, #list do
      local first, other = list[1], list[i]
      out[#out + 1] = string.format(
        "%s:%s: %s %s and %s %s: `cosmic docs %s` answers both",
        other.file, other.line, first.module, first.symbol, other.module, other.symbol, name)
    end
  end
  table.sort(out)
  return out, anchors
end

--- Lines as one source file's text.
local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- An anchor module of one documented string field, `field`.
local function anchor(name: string, field: string): string
  return source(
    "--- Doc anchors.",
    "local record " .. name,
    "  --- what " .. field .. " means here",
    "  " .. field .. ": string",
    "end",
    "local value: " .. name .. " = { " .. field .. " = \"" .. field .. "\" }",
    "return value")
end

--- Two anchors sharing a bare name are flagged.
local function test_two_anchors_sharing_a_name_are_flagged(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/verbs.tl"] = anchor("Verbs", "test"),
    ["cosmic/shapes.tl"] = anchor("Shapes", "test"),
  })
  local found = colliding(db)
  assert(#found == 1 and found[1]:find(
    "cosmic.shapes Shapes.test and cosmic.verbs Verbs.test: `cosmic docs test` answers both",
    1, true) ~= nil, table.concat(found, "\n"))
end

--- An anchor may share its name with a real member -- a function, or
--- a field of a record a function hands out -- and anchors with names
--- of their own do not collide.
local function test_an_anchor_beside_a_real_member_is_allowed(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/verbs.tl"] = anchor("Verbs", "test"),
    ["cosmic/shapes.tl"] = anchor("Shapes", "tests"),
    ["cosmic/thing.tl"] = source(
      "local record Thing",
      "  record Miss",
      "    --- where it went wrong",
      "    test: string",
      "  end",
      "end",
      "--- Tests it.",
      "function Thing.test(): Thing.Miss return { test = \"x\" } end",
      "return Thing"),
  })
  local found = colliding(db)
  assert(#found == 0, table.concat(found, "\n"))
end

--- The tree's own anchors, read from the database the build wrote.
local function test_no_two_doc_anchors_share_a_name()
  -- SQLite's open of it puts its bytes in the key (build/test.tl keys
  -- o/cosmic.db, alone of o/), so the test runs again whenever a build
  -- rewrites it.
  local db = assert(Sqlite.open("o/cosmic.db", false))
  local found, anchors = colliding(db)
  assert(db:close())
  -- The records the rule is for are found as anchors, so a change to
  -- what counts as one cannot leave the check vacuous.
  for _, expected in ipairs({ "cosmic.cli Cli", "cosmic.layout Layout",
                              "cosmic.entrypoint Entrypoint", "cosmic.errno Errno" }) do
    assert(anchors[expected], expected .. " is no longer taken for a doc anchor")
  end
  assert(#found == 0, "doc anchors sharing a name, which `cosmic docs <name>` " ..
    "answers with both -- rename one:\n" .. table.concat(found, "\n"))
end
