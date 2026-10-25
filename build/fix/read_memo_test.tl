--- What `cosmic fix` keeps of a parse ([`build.fix.read_memo`]): what comes back answers every line as the parse did, a row is
--- never answered for another text, and a row that does not read is a miss.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local ast = require("build.ast")
local check_memo = require("build.check_memo")
local link_text = require("build.link_text")
local links = require("build.links")
local near = require("build.fix.near")
local read_memo = require("build.fix.read_memo")
local teal = require("build.teal")
local tree_checks = require("build.tree_checks")

--- Real files of the tree, read to hold what is kept to what the parse says of them.
Test.policy{
  grants = {
    { path = "build/", letters = "r" },
    { path = "cosmic/", letters = "r" },
    { path = "lang/", letters = "r" },
  },
}

local built = assert(teal.load())

--- Source text of a small module whose comments stand at different places.
local small = [[
--- A module that holds a record and a function, for a link to name [`Box`] or [`Box.grow`].
local Fs = require("cosmic.fs")
local String = require("cosmic.string")

--- A box: [`Fs.read`] fills it.
local record Box
  --- How big, see [`Box.grow`].
  size: integer
  --- The words: [`String.trim`].
  words: {string}
end

local helper = 3

--- Grows `box` by `by`, as [`helper`] says.
function Box.grow(self: Box, by: integer): integer
  local inner = by + 1
  -- a plain comment naming [`inner`]
  return self.size + inner
end

--- Counts tests: it prints "%d tests" and adds a count .. " files".
local function count(n: integer): string
  return n .. " files"
end

return Box
]]

--- The text of `name` in the tree.
local function text_of(name: string): string
  return (assert(Fs.read(name)))
end

--- What a parse of `source` gives, as the phases after the layout take it.
local function read_of(file: string, source: string): read_memo.Read, ast.Parsed
  local parsed = (assert(ast.parse(built, source, file)))
  local read: read_memo.Read = { facts = links.facts(parsed, source) }
  local candidates: {near.Candidate} = { { source_symbol = file, text = "one", line = 3, method = true },
    { source_symbol = file .. "2", text = "two\twith a tab", line = 9 } }
  read.ready = candidates
  read.plurals = tree_checks.plurals_in("build/" .. file, source, parsed)
  return read, parsed
end

--- The names `declared` sees, those it holds and `everywhere`, which it inherits.
local function seen(declared: link_text.Declared, everywhere: {string: boolean}): {string: boolean}
  local out: mut {string: boolean} = {}
  for name in pairs(declared.names) do out[name] = true end
  for name in pairs(everywhere) do out[name] = true end
  return out
end

--- Asserts that what a memo keeps of `file`'s parse answers as the parse does.
local function holds(file: string, source: string)
  local read, parsed = read_of(file, source)
  local db = assert(Sqlite.memory())
  assert(check_memo.prepare(db, "laid"))
  read_memo.put(db, "salt", file, source, read, parsed)
  local back = assert(read_memo.get(db, "salt", built, file, source), file .. " does not read back")
  assert(back.facts.source == source and back.facts.known.parsed)
  assert(#back.facts.blocks == #read.facts.blocks, file)
  for i, block in ipairs(read.facts.blocks) do
    local other = back.facts.blocks[i]
    assert(other.line == block.line and other.text == block.text, file .. ": a block moved")
    assert((other.starts == nil) == (block.starts == nil), file .. ": starts")
    local kept_starts = other.starts or {}
    for j, at in ipairs(block.starts or {}) do
      assert(kept_starts[j] == at, file .. ": a start moved")
    end
  end
  for name in pairs(read.facts.known.module_level) do
    assert(back.facts.known.module_level[name] == true, file .. ": " .. name .. " is not module level")
  end
  for name in pairs(back.facts.known.module_level) do
    assert(read.facts.known.module_level[name] == true, file .. ": " .. name .. " is made up")
  end
  -- Every line a link can be on, and lines that are no comment's: the kept ones and the ones read off a parse then.
  local lines: mut {integer} = {}
  for line = 1, #(source:gsub("[^\n]", "")) + 1 do lines[#lines + 1] = line end
  for _, line in ipairs(lines) do
    local want, got = read.facts.known.at(line), back.facts.known.at(line)
    local wanted_names = seen(want, read.facts.known.everywhere or {})
    for name in pairs(wanted_names) do
      assert(got.names[name] == true, file .. " line " .. line .. ": " .. name .. " is not kept")
    end
    for name in pairs(seen(got, back.facts.known.everywhere or {})) do
      assert(wanted_names[name] == true, file .. " line " .. line .. ": " .. name .. " is made up")
    end
    for name, module in pairs(want.aliases) do
      assert(got.aliases[name] == module, file .. " line " .. line .. ": alias " .. name)
    end
    for name, module in pairs(got.aliases) do
      assert(want.aliases[name] == module, file .. " line " .. line .. ": alias " .. name .. " made up")
    end
  end
  local ready = assert(back.ready)
  assert(#ready == 2 and ready[1].method == true and ready[2].text == "two\twith a tab" and ready[2].method == nil, file)
  local wanted, got = read.plurals, back.plurals
  assert((wanted == nil) == (got == nil), file .. ": plurals")
  if wanted ~= nil and got ~= nil then
    assert(got.source == source and #got.sites == #wanted.sites, file .. ": sites")
    for i, site in ipairs(wanted.sites) do
      for j, field in ipairs(site) do assert(got.sites[i][j] == field, file .. ": a site moved") end
    end
  end
end

local function test_what_comes_back_answers_every_line_as_the_parse_did()
  holds("small.tl", small)
end

local function test_what_comes_back_answers_as_the_parse_did_for_files_of_the_tree()
  for _, name in ipairs({ "build/clock.tl", "build/links.tl", "build/fix/near.tl", "build/fix/laid.tl", "build/plural.tl",
      "cosmic/fs.tl", "cosmic/string.tl", "build/link_text.tl", "build/check_memo.tl", "lang/lexer.tl" }) do
    holds(name, text_of(name))
  end
end

local function test_a_file_with_no_comment_is_kept_too()
  holds("bare.tl", "local x = 1\nreturn x\n")
end

local function test_a_row_is_answered_for_its_text_and_salt_alone()
  local db = assert(Sqlite.memory())
  assert(check_memo.prepare(db, "laid"))
  local read, parsed = read_of("small.tl", small)
  read_memo.put(db, "salt", "small.tl", small, read, parsed)
  assert(read_memo.get(db, "salt", built, "small.tl", small) ~= nil)
  assert(read_memo.get(db, "other", built, "small.tl", small) == nil, "a row of other code was read")
  assert(read_memo.get(db, "salt", built, "small.tl", small .. "\n") == nil, "a row of other text was read")
  assert(read_memo.get(db, "salt", built, "other.tl", small) == nil, "a row of another file was read")
end

--- Whether the memo still answers for `small` once its one row is `changed` (the row's text in, the text it is to be out).
local function answers_after(changed: function(text: string): string): boolean
  local db = assert(Sqlite.memory())
  assert(check_memo.prepare(db, "laid"))
  local read, parsed = read_of("small.tl", small)
  read_memo.put(db, "salt", "small.tl", small, read, parsed)
  local rows = assert(Sqlite.rows(db, "SELECT value FROM check_memo WHERE kind = 'laid'"))
  local text = assert(rows[1]):text(1)
  assert(Sqlite.run(db, "UPDATE check_memo SET value = ?1", { { text = changed(text) } }))
  return read_memo.get(db, "salt", built, "small.tl", small) ~= nil
end

local function test_a_row_that_does_not_read_is_a_miss()
  assert(answers_after(function(text: string): string return text end), "the row as it was did not read")
  assert(not answers_after(function(): string return "" end), "no version")
  assert(not answers_after(function(text: string): string return text .. "\nZ\tx" end), "an unknown row")
  assert(not answers_after(function(text: string): string
    return (text:gsub("\nL\t(%d+)\t(%d+)", "\nL\t%1\tx", 1))
  end),
    "a line that is none")
  assert(not answers_after(function(text: string): string return (text:gsub("^V\t1", "V\t2")) end), "another version")
end

local function test_the_code_that_names_a_row_holds_what_the_readers_call()
  local held: mut {string: boolean} = {}
  for _, name in ipairs(read_memo.roots) do held[name] = true end
  for _, name in ipairs(read_memo.alone) do held[name] = true end
  -- [`tree_checks.plurals_in`] reads the sites of a plural in a parse by a module of its own, which [`build.tree_checks`] holds
  -- alone: an edit to it must miss the plurals a row kept.
  local source = text_of("build/tree_checks.tl")
  local from = assert(source:find("function tree_checks.plurals_in(", 1, true))
  local upto = assert(source:find("\nend\n", from, true))
  local body = source:sub(from, upto)
  for alias, module in pairs({ PluralSites = "build.plural_sites" }) do
    if body:find(alias .. ".", 1, true) ~= nil then
      assert(held[module] == true, module .. " is called by plurals_in and is not in the code a row is keyed by")
    end
  end
end
