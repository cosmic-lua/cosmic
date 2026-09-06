#!/usr/bin/env cosmic
--- Tests for cosmic.doc.mentions: FTS5-ranked and plain-fallback search
--- over the shipped guides and module docs for a symbol's mentions.

local mentions = require("cosmic.doc.mentions")

local function source_set(list: {mentions.Mention}): {string: boolean}
  local set: {string: boolean} = {}
  for _, m in ipairs(list) do set[m.source] = true end
  return set
end

local function mention_key_set(list: {mentions.Mention}): {string: boolean}
  local set: {string: boolean} = {}
  for _, m in ipairs(list) do set[m.source .. "|" .. m.line] = true end
  return set
end

-- The shipped guides teach fs.read in more than one place; the symbol
-- page should list every one of them, not just the ones a person
-- happens to grep for.
local function test_fs_read_lists_guides_that_teach_it()
  local list = mentions.mentions("cosmic.fs.read")
  local sources = source_set(list)
  assert(sources["guide.recipes"], "expected guide.recipes among mentions")
  assert(sources["guide.checking"], "expected guide.checking among mentions")
end

-- docs/guides/recipes.md's "CLI script skeleton" mentions fs.read only
-- inside a ```teal fence — proof that fenced code counts as a mention,
-- not just prose.
local function test_fenced_code_mention_counts()
  local list = mentions.mentions("cosmic.fs.read")
  local found = false
  for _, m in ipairs(list) do
    if m.source == "guide.recipes" and m.text:find("read_err", 1, true) then
      found = true
    end
  end
  assert(found, "expected the fenced 'read_err' line from recipes.md among mentions")
end

-- A symbol nobody else names lists nothing, and the render is the empty
-- string a caller uses to skip the "Mentioned in:" section entirely.
local function test_unmentioned_symbol_lists_nothing()
  local list = mentions.mentions("cosmic.doc.mentions.zzz_never_mentioned_anywhere_xyz")
  assert(#list == 0, "expected no mentions, got " .. #list)
  assert(mentions.render(list) == "", "expected an empty render for an empty list")
end

-- The fallback path (forced via the _force_plain test hook, since a
-- live cosmic build always has FTS5) must find the same mentions as the
-- ranked path — a plain string.find can't rank, but it must not miss
-- anything FTS5 finds.
local function test_plain_fallback_finds_the_same_set()
  local ranked = mentions.mentions("cosmic.fs.read")
  mentions._force_plain = true
  local plain = mentions.mentions("cosmic.fs.read")
  mentions._force_plain = false

  assert(#plain == #ranked,
    "expected the same mention count, got " .. #plain .. " vs " .. #ranked)
  local ranked_keys = mention_key_set(ranked)
  local plain_keys = mention_key_set(plain)
  for k in pairs(ranked_keys) do
    assert(plain_keys[k], "plain fallback missing ranked mention " .. k)
  end
end

-- Rendering formats a non-empty list into a labeled section, and the
-- list itself never carries the symbol's own entry.
local function test_render_formats_a_mentioned_in_section()
  local list = mentions.mentions("cosmic.fs.read")
  local rendered = mentions.render(list)
  assert(rendered:find("Mentioned in:", 1, true), "expected a 'Mentioned in:' header")
  assert(rendered:find("guide.recipes", 1, true), "expected guide.recipes in the rendering")
  for _, m in ipairs(list) do
    assert(m.source ~= "cosmic.fs.read",
      "the symbol's own entry should never appear in its own mentions")
  end
end

-- qualify() derives the fully-qualified name from a module's doc.file,
-- including the record-method colon spelling.
local function test_qualify_derives_full_names()
  assert(mentions.qualify("cosmic/fs.tl", "read") == "cosmic.fs.read")
  assert(mentions.qualify("cosmic/fs/init.tl", "read") == "cosmic.fs.read")
  assert(mentions.qualify("cosmic/sqlite/init.tl", "Database", "query")
    == "cosmic.sqlite.Database:query")
end
