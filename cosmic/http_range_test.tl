--- Cases for [`Http.range`] and [`Http.none_match`], the reading of a
--- request's Range and If-None-Match; cosmic/http_range_fuzz_test.tl
--- holds them to their properties over any bytes.

local Http = require("cosmic.http")

--- What `Http.range(header, size)` answers, as text: "whole",
--- "unsatisfiable", or the span's "first-last".
local function ranged(header: string | nil, size: integer): string
  local r = Http.range(header, size)
  if r.kind == "span" then return ("%d-%d"):format(r.first, r.last) end
  assert(r.first == nil and r.last == nil, "a bound set for " .. r.kind)
  return r.kind
end

local function test_each_form_of_one_range_is_a_span()
  assert(ranged("bytes=0-499", 1000) == "0-499")
  assert(ranged("bytes=500-", 1000) == "500-999")
  assert(ranged("bytes=-200", 1000) == "800-999")
  assert(ranged("bytes=7-7", 10) == "7-7")
end

local function test_a_range_past_the_end_is_clamped_to_it()
  assert(ranged("bytes=5-99", 10) == "5-9")
  assert(ranged("bytes=-99", 10) == "0-9")
end

local function test_no_header_is_whole()
  assert(ranged(nil, 10) == "whole")
end

local function test_the_unit_is_bytes_in_any_case()
  assert(ranged("Bytes=0-1", 10) == "0-1")
  assert(ranged("BYTES=0-1", 10) == "0-1")
  assert(ranged("items=0-1", 10) == "whole")
  assert(ranged("bytes 0-1", 10) == "whole")
end

local function test_more_than_one_range_is_whole()
  assert(ranged("bytes=0-1,4-5", 10) == "whole")
  assert(ranged("bytes=0-1, 0-1", 10) == "whole")
end

local function test_empty_list_elements_and_spaces_beside_commas_are_read()
  assert(ranged("bytes=0-1,", 10) == "0-1")
  assert(ranged("bytes=, ,0-1 ,\t", 10) == "0-1")
  assert(ranged("  bytes=0-1  ", 10) == "0-1")
  assert(ranged("bytes=,", 10) == "whole")
  assert(ranged("bytes=", 10) == "whole")
end

local function test_a_range_it_cannot_read_is_whole()
  for _, header in ipairs({ "bytes= 0-1", "bytes=0 -1", "bytes=0- 1", "bytes=+0-1", "bytes=0-+1",
      "bytes=-", "bytes=--1", "bytes=1-2-3", "bytes=a-b", "bytes =0-1", "bytes=0x1-2", "bytes=\xd9\xa1-",
      "=0-1", "" }) do
    assert(ranged(header, 10) == "whole", header)
  end
end

local function test_a_last_before_the_first_is_whole_not_unsatisfiable()
  assert(ranged("bytes=5-4", 10) == "whole")
  assert(ranged("bytes=50-40", 10) == "whole")
end

local function test_a_range_holding_no_byte_is_unsatisfiable()
  assert(ranged("bytes=10-", 10) == "unsatisfiable")
  assert(ranged("bytes=10-20", 10) == "unsatisfiable")
  assert(ranged("bytes=-0", 10) == "unsatisfiable")
  assert(ranged("bytes=0-", 0) == "unsatisfiable")
  assert(ranged("bytes=0-0", 0) == "unsatisfiable")
  assert(ranged("bytes=-0", 0) == "unsatisfiable")
end

-- RFC 9110 14.1.1 holds a suffix range of an empty representation
-- satisfiable, with no bytes a 206 could carry.
local function test_a_suffix_of_an_empty_representation_is_whole()
  assert(ranged("bytes=-5", 0) == "whole")
end

local function test_counts_past_the_largest_integer_compare_as_they_are()
  local huge = string.rep("9", 40)
  assert(ranged("bytes=0-" .. huge, 10) == "0-9")
  assert(ranged("bytes=" .. huge .. "-", 10) == "unsatisfiable")
  assert(ranged("bytes=-" .. huge, 10) == "0-9")
  assert(ranged("bytes=" .. huge .. "-" .. huge, math.maxinteger) == "unsatisfiable")
  -- Both read as the largest integer, but the last is still before the first.
  assert(ranged("bytes=" .. huge .. "-" .. string.rep("9", 39) .. "8", 10) == "whole")
  assert(ranged("bytes=00000000000000000000000000003-0000000000000000000000000000004", 10) == "3-4")
  assert(ranged("bytes=9223372036854775806-", math.maxinteger) == "9223372036854775806-9223372036854775806")
end

local function test_a_size_that_is_no_count_raises()
  local sizes: {any} = { -1, 1.5, "1" }
  for _, size in ipairs(sizes) do
    local ok, why = pcall(Http.range, "bytes=0-1", size as integer)
    assert(not ok and tostring(why):find("size", 1, true), tostring(why))
  end
end

local function test_none_match_compares_weakly()
  assert(Http.none_match('"v1"', '"v1"'))
  assert(Http.none_match('W/"v1"', '"v1"'))
  assert(Http.none_match('"v1"', 'W/"v1"'))
  assert(Http.none_match('W/"v1"', 'W/"v1"'))
  assert(not Http.none_match('"v2"', '"v1"'))
  assert(not Http.none_match('"V1"', '"v1"'))
end

local function test_none_match_reads_each_tag_of_a_list()
  assert(Http.none_match('"a", "b" ,\t"v1"', '"v1"'))
  assert(Http.none_match(',,"v1",', '"v1"'))
  assert(not Http.none_match('"a", "b"', '"v1"'))
end

local function test_a_star_matches_any_tag()
  assert(Http.none_match("*", '"v1"'))
  assert(Http.none_match(" * ", 'W/"v1"'))
end

local function test_no_header_matches_nothing()
  assert(not Http.none_match(nil, '"v1"'))
  assert(not Http.none_match("", '"v1"'))
end

-- A comma is a byte an opaque tag may hold, so a list is not split on
-- every comma.
local function test_a_tag_holding_a_comma_is_one_tag()
  assert(Http.none_match('"a,b"', '"a,b"'))
  assert(not Http.none_match('"a,b"', '"b"'))
end

local function test_an_element_that_is_no_tag_matches_nothing_and_the_rest_are_read()
  assert(not Http.none_match("v1", '"v1"'))
  assert(not Http.none_match('w/"v1"', '"v1"'))
  assert(not Http.none_match('"v1" x', '"v1"'))
  assert(not Http.none_match('"v1', '"v1"'))
  assert(not Http.none_match('v0, "v1', '"v1"'))
  assert(Http.none_match('junk, "v1"', '"v1"'))
  assert(Http.none_match('"x" "y", "v1"', '"v1"'))
  assert(Http.none_match('*, "v1"', '"v1"'))
  assert(not Http.none_match('*, "v2"', '"v1"'))
end

local function test_an_etag_that_is_no_entity_tag_raises()
  for _, etag in ipairs({ "v1", "", '"v1', 'W/v1', '"v 1"', '"v1" ' }) do
    local ok, why = pcall(Http.none_match, '"v1"', etag)
    assert(not ok and tostring(why):find("entity tag", 1, true), etag)
  end
end
