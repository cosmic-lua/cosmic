#!/usr/bin/env cosmic
--- Tests for fuzzy string matching utilities.

local fuzzy = require("cosmic.fuzzy")

-- levenshtein tests

local function test_levenshtein_identical()
  assert(fuzzy.levenshtein("hello", "hello") == 0, "identical strings should have distance 0")
  assert(fuzzy.levenshtein("", "") == 0, "empty strings should have distance 0")
end
test_levenshtein_identical()

local function test_levenshtein_empty()
  assert(fuzzy.levenshtein("", "abc") == 3, "empty to 'abc' should be 3")
  assert(fuzzy.levenshtein("abc", "") == 3, "'abc' to empty should be 3")
end
test_levenshtein_empty()

local function test_levenshtein_single_edit()
  -- insertion
  assert(fuzzy.levenshtein("abc", "abcd") == 1, "insertion should be distance 1")
  -- deletion
  assert(fuzzy.levenshtein("abcd", "abc") == 1, "deletion should be distance 1")
  -- substitution
  assert(fuzzy.levenshtein("abc", "aXc") == 1, "substitution should be distance 1")
end
test_levenshtein_single_edit()

local function test_levenshtein_common_typos()
  assert(fuzzy.levenshtein("Database", "Databse") == 1, "transposition-like typo")
  assert(fuzzy.levenshtein("spawn", "spwan") == 2, "adjacent swap")
  assert(fuzzy.levenshtein("sqlite", "sqlit") == 1, "missing letter")
  assert(fuzzy.levenshtein("argon2", "argonn2") == 1, "extra letter")
end
test_levenshtein_common_typos()

local function test_levenshtein_case_sensitive()
  -- levenshtein is case-sensitive by default
  assert(fuzzy.levenshtein("ABC", "abc") == 3, "case differences count as substitutions")
end
test_levenshtein_case_sensitive()

-- find_similar tests

local function test_find_similar_exact_match()
  local candidates = {"foo", "bar", "baz"}
  local results = fuzzy.find_similar("foo", candidates, 0)
  assert(#results == 1, "should find exact match")
  assert(results[1] == "foo", "should return foo")
end
test_find_similar_exact_match()

local function test_find_similar_typo()
  local candidates = {"Database", "Statement", "Connection"}
  local results = fuzzy.find_similar("Databse", candidates, 2)
  assert(#results == 1, "should find one match")
  assert(results[1] == "Database", "should find Database for Databse")
end
test_find_similar_typo()

local function test_find_similar_case_insensitive()
  local candidates = {"Database", "Statement"}
  local results = fuzzy.find_similar("database", candidates, 0)
  assert(#results == 1, "should find case-insensitive match")
  assert(results[1] == "Database", "should preserve original case in result")
end
test_find_similar_case_insensitive()

local function test_find_similar_sorted_by_distance()
  local candidates = {"abc", "abcd", "abcde", "xyz"}
  local results = fuzzy.find_similar("abc", candidates, 3)
  assert(results[1] == "abc", "exact match should be first")
  assert(results[2] == "abcd", "distance 1 should be second")
  assert(results[3] == "abcde", "distance 2 should be third")
end
test_find_similar_sorted_by_distance()

local function test_find_similar_alphabetical_tiebreaker()
  local candidates = {"cat", "bat", "rat"}
  local results = fuzzy.find_similar("hat", candidates, 1)
  -- all have distance 1, should be sorted alphabetically
  assert(results[1] == "bat", "alphabetically first should be first, got: " .. (results[1] or "nil"))
  assert(results[2] == "cat", "alphabetically second should be second")
  assert(results[3] == "rat", "alphabetically third should be third")
end
test_find_similar_alphabetical_tiebreaker()

local function test_find_similar_no_matches()
  local candidates = {"apple", "banana", "cherry"}
  local results = fuzzy.find_similar("xyz", candidates, 2)
  assert(#results == 0, "should find no matches for distant query")
end
test_find_similar_no_matches()

local function test_find_similar_deduplicates()
  local candidates = {"foo", "foo", "bar", "foo"}
  local results = fuzzy.find_similar("foo", candidates, 0)
  assert(#results == 1, "should deduplicate results")
end
test_find_similar_deduplicates()

local function test_find_similar_default_max_distance()
  local candidates = {"abcdef"}
  -- default max_distance is 3
  local results = fuzzy.find_similar("abc", candidates)
  assert(#results == 1, "should use default max_distance of 3")
end
test_find_similar_default_max_distance()

print("All fuzzy tests passed")
