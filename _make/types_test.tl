#!/usr/bin/env cosmic
-- The kind vocabulary is declared twice, and this is what holds the
-- two copies equal.
--
-- `Kind` is an enum, so it is a type, and Teal erases types. Nothing
-- that `require`s `_make.types` can ask what the kinds are -- which is
-- why `types.kinds` exists, and why the enum and the list can disagree
-- with nobody noticing.
--
-- The checker gives one direction free: `kinds` is typed `{Kind}`, so
-- an entry that is not a kind fails `--make check`. This file is the
-- other direction, and it is the ONLY place in the tree that reads a
-- source file to recover a declaration. It reads one, at the file that
-- declares it, to compare two lists it already has -- not to build a
-- vocabulary every downstream check then depends on. A parse that
-- breaks fails here, by name, instead of quietly shrinking what some
-- other test covers.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local types = require("_make.types")

local SOURCE < const > = "_make/types.tl"

--- The set of a list's entries.
--- @param list {string} The entries
--- @return {string: boolean} The set
local function set_of(list: {string}): {string: boolean}
  local out: {string: boolean} = {}
  for _, name in ipairs(list) do
    out[name] = true
  end
  return out
end

--- Names in `want` that `have` does not hold, sorted.
--- @param want {string: boolean} The names looked for
--- @param have {string: boolean} The names present
--- @return {string} The missing names
local function missing(want: {string: boolean}, have: {string: boolean}): {string}
  local out: {string} = {}
  for name in pairs(want) do
    if not have[name] then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

--- The enum's members, read from the enum's own source.
---
--- Line-based, and `[^"]+` rather than a character class: a member is a
--- quoted string alone on its line, whatever it is spelled with. The
--- pattern this replaced matched `[%w%-]+` between the quotes, so a
--- kind named with an underscore matched nothing at all and vanished
--- from the vocabulary without a word.
--- @return {string: boolean} The set of members
local function enum_members(): {string: boolean}
  local out: {string: boolean} = {}
  local inside = false
  local closed = false
  for line in check.must(fs.read(SOURCE)):gmatch("([^\n]*)\n?") do
    local text = line:match("^%s*(.-)%s*$")
    if not inside then
      inside = text == "enum Kind"
    elseif text == "end" then
      closed = true
      break
    else
      local member = text:match("^\"([^\"]+)\"$")
      if member then
        out[member] = true
      end
    end
  end
  assert(inside, SOURCE .. ": no line reading `enum Kind`")
  assert(closed, SOURCE .. ": the `enum Kind` block never closes")
  return out
end

-- The enum and the list say the same thing. Both directions by name,
-- because the two failures read differently: a member with no entry is
-- a kind no `require` can see, and an entry with no member is a kind
-- the checker would have caught only if some other code used it.
local function test_the_kinds_list_is_the_enum()
  local members = enum_members()
  local listed = set_of(types.kinds)

  local unlisted = missing(members, listed)
  assert(#unlisted == 0, SOURCE .. ": `enum Kind` has " ..
    table.concat(unlisted, ", ") .. " but `make_types.kinds` does not " ..
    "-- add it there, in the enum's order, or nothing that requires " ..
    "this module can see the kind")

  local undeclared = missing(listed, members)
  assert(#undeclared == 0, SOURCE .. ": `make_types.kinds` has " ..
    table.concat(undeclared, ", ") .. " but `enum Kind` does not " ..
    "-- one of the two was edited alone")

  local distinct = 0
  for _ in pairs(listed) do
    distinct = distinct + 1
  end
  assert(#types.kinds == distinct, SOURCE ..
    ": `make_types.kinds` lists a kind twice")
end
test_the_kinds_list_is_the_enum()

-- `lint_kinds`'s doc comment states a law -- "nearly everything ...
-- `testdata` is the one exception" -- and a law stated only in prose is
-- how a new kind slips past the linter. Nothing catches that: the
-- checker enforces that every KEY is a kind, never that every kind is
-- a key. So a kind added to the enum is silently unlinted until
-- somebody re-reads this table, which is the same shape of drift the
-- skill ratchet exists for, one level down.
local function test_lint_reads_every_kind_but_testdata()
  for _, kind in ipairs(types.kinds) do
    local excused = kind == "testdata"
    local read = types.lint_kinds[kind] or false
    assert(read ~= excused, "_make/types.tl: `lint_kinds` " ..
      (read and "reads" or "skips") .. " '" .. kind .. "', and its doc " ..
      "comment says lint reads every kind but `testdata`. Add the kind " ..
      "to the table, or amend the comment to say why this one is also " ..
      "exempt -- an unlinted kind is not a thing to decide by omission")
  end
end
test_lint_reads_every_kind_but_testdata()

print("all model type tests passed")
