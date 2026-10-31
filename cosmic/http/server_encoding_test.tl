--- [`Server.encoding`] chooses a content coding from an Accept-Encoding
--- header as RFC 9110 section 12.5.3 says.

local Server = require("cosmic.http.server")

local function chosen(header: string?, offered?: {string}): string
  return Server.encoding(header, offered) or "none"
end

-- No header accepts identity; an empty one accepts identity alone.
local function test_no_header_and_an_empty_one_choose_identity()
  assert(chosen(nil) == "identity")
  assert(chosen("") == "identity")
  assert(chosen("  ,, ") == "identity")
end

-- The best weight wins, ties go to the server's order, names compare in
-- any case, and a weight of 0 refuses.
local function test_the_best_weight_wins()
  assert(chosen("gzip, zstd") == "zstd")
  assert(chosen("gzip, zstd", { "gzip", "zstd" }) == "gzip")
  assert(chosen("gzip;q=1, zstd;q=0.999") == "gzip")
  assert(chosen("gzip;q=0.5, zstd;q=0.4") == "gzip")
  assert(chosen(" ZsTd ; Q=0.5 , GZIP;q=0.6") == "gzip")
  assert(chosen("zstd;q=0, gzip;q=0.001") == "gzip")
  assert(chosen("zstd;q=0.000, gzip;q=0") == "identity")
  assert(chosen("x-gzip") == "gzip")
  assert(chosen("deflate, br") == "identity")
  assert(chosen("gzip;q=1.000, zstd;q=1.0") == "zstd")
end

-- `*` covers the codings not named, and a coding named wins over it.
local function test_star_stands_for_the_codings_not_named()
  assert(chosen("*") == "zstd")
  assert(chosen("gzip, *;q=0.5") == "gzip")
  assert(chosen("*;q=0.5, zstd;q=0.2") == "gzip")
  assert(chosen("*;q=0, gzip") == "gzip")
  assert(chosen("*;q=0, br") == "none")
end

-- Identity is accepted unless refused by name or by a `*;q=0` that does
-- not name it; a client that weighs it above every coding gets it.
local function test_identity_is_accepted_unless_refused()
  assert(chosen("identity;q=0") == "none")
  assert(chosen("identity;q=0, br") == "none")
  assert(chosen("*;q=0") == "none")
  assert(chosen("*;q=0, identity") == "identity")
  assert(chosen("*;q=0, identity;q=0.1") == "identity")
  assert(chosen("gzip;q=0.5, identity") == "identity")
  assert(chosen("gzip;q=0.5, identity;q=0.5") == "gzip")
  assert(chosen("gzip;q=0, identity;q=0") == "none")
end

-- An element that is no coding, or has a weight that is no qvalue, or a
-- parameter other than the weight, is ignored; the first weight of a
-- coding stands.
local function test_a_malformed_element_is_ignored()
  assert(chosen("gzip;q=2") == "identity")
  assert(chosen("gzip;q=0.5555") == "identity")
  assert(chosen("gzip;q=1.5, zstd") == "zstd")
  assert(chosen("gzip;q = 1") == "identity")
  assert(chosen("gzip;q=") == "identity")
  assert(chosen("gzip;level=5") == "identity")
  assert(chosen("gzip;q=0.5;x=1, zstd;q=0.1") == "zstd")
  assert(chosen("gzi p, @@@, gzip") == "gzip")
  assert(chosen("gzip;q=0, gzip") == "identity")
  assert(chosen("*;q=0, *") == "none")
  assert(chosen("gzip;q=.5") == "identity")
  assert(chosen("gzip;q=0.") == "identity")
end
