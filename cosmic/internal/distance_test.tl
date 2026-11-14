local Distance = require("cosmic.internal.distance")

local function test_the_reach_grows_with_the_word()
  assert(Distance.reach("ab") == 0, "a word of two letters has a reach")
  assert(Distance.reach("abc") == 1 and Distance.reach("abcdefg") == 1)
  assert(Distance.reach("abcdefgh") == 2 and Distance.reach("abcdefghijk") == 2)
  assert(Distance.reach("abcdefghijkl") == 3)
  -- Characters are counted, not bytes: three two-byte letters are a word of three.
  assert(Distance.reach("ééé") == 1 and Distance.reach("éé") == 0)
end

local function test_each_edit_counts_one_and_a_swap_of_neighbours_is_one()
  assert(Distance.between("search", "search", 2) == 0)
  assert(Distance.between("serch", "search", 2) == 1, "an insertion")
  assert(Distance.between("seearch", "search", 2) == 1, "a deletion")
  assert(Distance.between("sezrch", "search", 2) == 1, "a replacement")
  assert(Distance.between("serach", "search", 2) == 1, "a swap of two neighbours")
  assert(Distance.between("srach", "search", 2) == 2)
end

local function test_a_distance_past_the_reach_is_one_past_it()
  assert(Distance.between("abcdef", "uvwxyz", 2) == 3, "the distance was counted past the reach")
  assert(Distance.between("ab", "abcdefgh", 2) == 3, "a length too far apart was counted")
end
