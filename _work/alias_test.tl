#!/usr/bin/env cosmic
-- alias is a pure derivation over an item's id: determinism, chunk
-- shape, input folding, and the refusal arms are pinned directly,
-- with no store and no git involved.

local check = require("cosmic.check")
local alias = require("_work.alias")
local item = require("_work.item")
local ksuid = require("_work.ksuid")

local counter = 0

--- A deterministic id; later calls sort later.
local function fresh_id(): string
  counter = counter + 1
  return check.must(ksuid.encode(1700000000 + counter, ("\0"):rep(16)))
end

local function make(id: string, title: string): item.Item
  return check.must(item.decode({id = id, title = title}))
end

local function test_of_is_deterministic_and_chunked()
  local id = fresh_id()
  local a = alias.of(id)
  local b = alias.of(id)
  assert(a == b, "same id, same alias: " .. a .. " vs " .. b)
  assert(a:match("^[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]%-[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]$"),
    "XXXX-XXXX shape: " .. a)
  for _, bad in ipairs({"I", "L", "O", "U"}) do
    assert(not a:find(bad, 1, true), a .. " must not carry " .. bad)
  end
end
test_of_is_deterministic_and_chunked()

local function test_of_differs_across_ids()
  local a = alias.of(fresh_id())
  local b = alias.of(fresh_id())
  assert(a ~= b, "distinct ids should not collide in this test's small sample")
end
test_of_differs_across_ids()

local function test_chunk_shape()
  assert(alias.chunk("ABCDEFGH") == "ABCD-EFGH", alias.chunk("ABCDEFGH"))
end
test_chunk_shape()

local function test_resolve_folds_input()
  local id = fresh_id()
  local a = alias.of(id)
  local all: {item.Item} = {make(id, "a slice")}
  -- Exact case, lowercase, and hyphen dropped all name the same item.
  -- The ambiguous-letter fold-back property is pinned separately below
  -- (test_fold_covers_every_substitution and
  -- test_resolve_folds_ambiguous_letters) rather than here, because
  -- whether this particular alias contains a 0 or 1 to fold back
  -- depends on fresh_id()'s counter and cannot be relied on.
  assert(check.must(alias.resolve(all, a)) == id, "exact")
  assert(check.must(alias.resolve(all, a:lower())) == id, "lowercase")
  assert(check.must(alias.resolve(all, (a:gsub("%-", "")))) == id,
    "hyphen-free")
end
test_resolve_folds_input()

local function test_fold_covers_every_substitution()
  -- Direct, unconditional coverage of every clause fold() applies —
  -- independent of what characters any derived alias happens to
  -- contain. Each of the six ambiguous letters is asserted on its own,
  -- so deleting any one gsub clause turns exactly the assertions for
  -- its letters red.
  assert(alias.fold("o") == "0", "o folds to 0")
  assert(alias.fold("O") == "0", "O folds to 0")
  assert(alias.fold("i") == "1", "i folds to 1")
  assert(alias.fold("I") == "1", "I folds to 1")
  assert(alias.fold("l") == "1", "l folds to 1")
  assert(alias.fold("L") == "1", "L folds to 1")
  assert(alias.fold("a-b") == "AB", "hyphen stripped, case raised")
  assert(alias.fold("oOiIlL-") == "001111", "all six substitutions together")
end
test_fold_covers_every_substitution()

local function test_resolve_folds_ambiguous_letters()
  -- resolve() must apply fold() to its input, not just to the derived
  -- alias it compares against — checked here with a real, derived
  -- alias rather than a guarded assertion that only sometimes runs
  -- (the bug this test replaces): search fresh_id() draws until one's
  -- alias actually carries a 0 or 1 to substitute, then verify the
  -- reverse-substituted, still-ambiguous form still resolves.
  local id = ""
  local a = ""
  for _ = 1, 200 do
    local candidate_id = fresh_id()
    local candidate_alias = alias.of(candidate_id)
    if candidate_alias:find("0", 1, true) or candidate_alias:find("1", 1, true) then
      id = candidate_id
      a = candidate_alias
      break
    end
  end
  assert(id ~= "", "no alias with an ambiguous digit found in 200 tries")
  local all: {item.Item} = {make(id, "a slice")}
  local ambiguous = (a:gsub("0", "O"):gsub("1", "I"))
  assert(ambiguous ~= a, "reverse substitution must change the string")
  assert(check.must(alias.resolve(all, ambiguous)) == id,
    "ambiguous letters fold back through resolve")
end
test_resolve_folds_ambiguous_letters()

local function test_resolve_refuses_no_match()
  local all: {item.Item} = {make(fresh_id(), "a slice")}
  local id, err = alias.resolve(all, "ZZZZ-ZZZZ")
  assert(id == nil, "no item carries that alias")
  assert(err:find("no item matches alias", 1, true), err)
end
test_resolve_refuses_no_match()

local function test_resolve_refuses_and_names_a_collision()
  local one = fresh_id()
  local other = fresh_id()
  local a = alias.of(one)
  -- A real collision needs two ids that hash to the same alias, which
  -- is exactly what the alias is meant to make astronomically
  -- unlikely — so the arm is exercised directly instead: two records
  -- whose stored id is the same one, standing in for "two items with
  -- the same derived alias" without depending on finding one.
  local rigged = make(other, "another")
  rigged.id = one
  local all: {item.Item} = {make(one, "a slice"), rigged}
  local dup, derr = alias.resolve(all, a)
  assert(dup == nil, "ambiguous")
  assert(derr:find(one, 1, true) and derr:find("ambiguous", 1, true), derr)
end
test_resolve_refuses_and_names_a_collision()

local function test_is_alias_shape()
  assert(alias.is_alias_shape("Q4TX-9GMD"), "chunked alias")
  assert(alias.is_alias_shape("Q4TX9GMD"), "hyphen-free")
  assert(alias.is_alias_shape("q4tx-9gmd"), "case-insensitive")
  assert(not alias.is_alias_shape("Q4TX9GM"), "too short")
  assert(not alias.is_alias_shape("Q4TX9GMDX"), "too long")
  assert(not alias.is_alias_shape("QUTX9GMD"), "U is not in the alphabet")
  assert(not alias.is_alias_shape(""), "empty")
end
test_is_alias_shape()
