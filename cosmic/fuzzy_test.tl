#!/usr/bin/env cosmic
--- Tests for fuzzy string matching utilities.

local fuzzy = require("cosmic.fuzzy")

-- distance tests

local function test_distance_identical()
  assert(fuzzy.distance("hello", "hello") == 0, "identical strings should have distance 0")
  assert(fuzzy.distance("", "") == 0, "empty strings should have distance 0")
end
test_distance_identical()

local function test_distance_empty()
  assert(fuzzy.distance("", "abc") == 3, "empty to 'abc' should be 3")
  assert(fuzzy.distance("abc", "") == 3, "'abc' to empty should be 3")
end
test_distance_empty()

local function test_distance_single_edit()
  -- insertion
  assert(fuzzy.distance("abc", "abcd") == 1, "insertion should be distance 1")
  -- deletion
  assert(fuzzy.distance("abcd", "abc") == 1, "deletion should be distance 1")
  -- substitution
  assert(fuzzy.distance("abc", "aXc") == 1, "substitution should be distance 1")
end
test_distance_single_edit()

local function test_distance_common_typos()
  assert(fuzzy.distance("Database", "Databse") == 1, "transposition-like typo")
  assert(fuzzy.distance("spawn", "spwan") == 2, "adjacent swap")
  assert(fuzzy.distance("sqlite", "sqlit") == 1, "missing letter")
  assert(fuzzy.distance("argon2", "argonn2") == 1, "extra letter")
end
test_distance_common_typos()

local function test_distance_case_sensitive()
  -- distance is case-sensitive by default
  assert(fuzzy.distance("ABC", "abc") == 3, "case differences count as substitutions")
end
test_distance_case_sensitive()

local function test_distance_symmetry()
  -- distance(a,b) must equal distance(b,a) for all cases
  local cases: {{string, string}} = {
    {"kitten", "sitting"},
    {"a", "abcdef"},
    {"short", "a much longer string"},
    {"xyz", ""},
  }
  for _, p in ipairs(cases) do
    local d1 = fuzzy.distance(p[1], p[2])
    local d2 = fuzzy.distance(p[2], p[1])
    assert(d1 == d2, "distance should be symmetric: '" .. p[1] .. "' <-> '" .. p[2] .. "': " .. tostring(d1) .. " vs " .. tostring(d2))
  end
end
test_distance_symmetry()

local function test_distance_single_char()
  assert(fuzzy.distance("a", "b") == 1, "single char substitution")
  assert(fuzzy.distance("a", "a") == 0, "single char identical")
  assert(fuzzy.distance("a", "") == 1, "single char to empty")
  assert(fuzzy.distance("", "z") == 1, "empty to single char")
end
test_distance_single_char()

local function test_distance_asymmetric_lengths()
  -- when #a >> #b, the two-row optimization should swap to use less memory
  assert(fuzzy.distance("ab", "abcdefghij") == 8, "short vs long")
  assert(fuzzy.distance("abcdefghij", "ab") == 8, "long vs short")
  assert(fuzzy.distance("kitten", "sitting") == 3, "classic example")
  assert(fuzzy.distance("saturday", "sunday") == 3, "classic example 2")
end
test_distance_asymmetric_lengths()

local function test_distance_longer_strings()
  local a = string.rep("abc", 20) -- 60 chars
  local b = string.rep("abc", 20) -- identical
  assert(fuzzy.distance(a, b) == 0, "long identical strings")
  -- change one char in the middle
  local c = a:sub(1, 30) .. "X" .. a:sub(32)
  assert(fuzzy.distance(a, c) == 1, "long strings with one substitution")
end
test_distance_longer_strings()

local function test_levenshtein_alias()
  -- DEPRECATED alias, kept for the pinned bootstrap until the next pin
  -- advance (#1002); it must stay the same function as distance.
  assert(fuzzy.levenshtein == fuzzy.distance, "levenshtein should alias distance")
end
test_levenshtein_alias()

-- find_similar tests

local function test_find_similar_exact_match()
  local candidates = {"foo", "bar", "baz"}
  local results = fuzzy.find_similar("foo", candidates, {max_distance = 0})
  assert(#results == 1, "should find exact match")
  assert(results[1].value == "foo", "should return foo")
  assert(results[1].distance == 0, "exact match should have distance 0")
end
test_find_similar_exact_match()

local function test_find_similar_typo()
  local candidates = {"Database", "Statement", "Connection"}
  local results = fuzzy.find_similar("Databse", candidates, {max_distance = 2})
  assert(#results == 1, "should find one match")
  assert(results[1].value == "Database", "should find Database for Databse")
  assert(results[1].distance == 1, "Databse -> Database is one edit")
end
test_find_similar_typo()

local function test_find_similar_case_insensitive()
  local candidates = {"Database", "Statement"}
  local results = fuzzy.find_similar("database", candidates, {max_distance = 0})
  assert(#results == 1, "should find case-insensitive match")
  assert(results[1].value == "Database", "should preserve original case in result")
end
test_find_similar_case_insensitive()

local function test_find_similar_sorted_by_distance()
  local candidates = {"abc", "abcd", "abcde", "xyz"}
  local results = fuzzy.find_similar("abc", candidates, {max_distance = 3})
  assert(results[1].value == "abc", "exact match should be first")
  assert(results[2].value == "abcd", "distance 1 should be second")
  assert(results[3].value == "abcde", "distance 2 should be third")
  assert(results[2].distance == 1, "abcd should carry its distance")
  assert(results[3].distance == 2, "abcde should carry its distance")
end
test_find_similar_sorted_by_distance()

local function test_find_similar_alphabetical_tiebreaker()
  local candidates = {"cat", "bat", "rat"}
  local results = fuzzy.find_similar("hat", candidates, {max_distance = 1})
  -- all have distance 1, should be sorted alphabetically
  local first = results[1] and results[1].value or "nil"
  assert(results[1].value == "bat", "alphabetically first should be first, got: " .. first)
  assert(results[2].value == "cat", "alphabetically second should be second")
  assert(results[3].value == "rat", "alphabetically third should be third")
end
test_find_similar_alphabetical_tiebreaker()

local function test_find_similar_no_matches()
  local candidates = {"apple", "banana", "cherry"}
  local results = fuzzy.find_similar("xyz", candidates, {max_distance = 2})
  assert(#results == 0, "should find no matches for distant query")
end
test_find_similar_no_matches()

local function test_find_similar_deduplicates()
  local candidates = {"foo", "foo", "bar", "foo"}
  local results = fuzzy.find_similar("foo", candidates, {max_distance = 0})
  assert(#results == 1, "should deduplicate results")
end
test_find_similar_deduplicates()

local function test_find_similar_default_max_distance()
  local candidates = {"abcdef"}
  -- default max_distance is 3, with or without an opts table
  local results = fuzzy.find_similar("abc", candidates)
  assert(#results == 1, "should use default max_distance of 3")
  local results2 = fuzzy.find_similar("abc", candidates, {})
  assert(#results2 == 1, "empty opts should also default max_distance to 3")
end
test_find_similar_default_max_distance()

local function test_find_similar_dedup_case_insensitive()
  -- dedup must be case-insensitive: {"Foo","foo"} produces 1 result
  local candidates = {"Foo", "foo"}
  local results = fuzzy.find_similar("foo", candidates, {max_distance = 0})
  assert(#results == 1,
    "case-insensitive dedup: expected 1 result for {Foo, foo}, got " .. #results)
end
test_find_similar_dedup_case_insensitive()

local function test_find_similar_limit()
  local candidates = {"abc", "abcd", "abcde", "abx"}
  local results = fuzzy.find_similar("abc", candidates, {max_distance = 3, limit = 2})
  assert(#results == 2, "limit should trim the result list, got " .. #results)
  assert(results[1].value == "abc", "limit keeps the closest matches")
  assert(results[2].value == "abcd", "distance 1 ties break alphabetically")
end
test_find_similar_limit()

print("All fuzzy tests passed")
