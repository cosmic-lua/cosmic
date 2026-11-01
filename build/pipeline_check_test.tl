--- The key a module's answer of the pipeline check is kept under ([`build.pipeline_check`]): it holds the ceilings of the
--- module's own file and no other's, so a stale answer is never served for a pin that moved, and a pin elsewhere costs nothing.
local PipelineCheck = require("build.pipeline_check")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

local digests: {string: string} = { ["a.tl"] = "da", ["b.tl"] = "db" }

local function test_a_plain_file_is_keyed_by_the_ceilings_of_its_own_name()
  local whole = PipelineCheck.whole(digests, false)
  local first = PipelineCheck.keyed("k", true, "a.tl", digests, whole)
  assert(first == PipelineCheck.keyed("k", true, "a.tl", digests, whole))
  -- A pin of another file moves nothing for it.
  local moved: {string: string} = { ["a.tl"] = "da", ["b.tl"] = "db2" }
  assert(first == PipelineCheck.keyed("k", true, "a.tl", moved, PipelineCheck.whole(moved, false)))
  -- Its own pin does, whether lowered, raised, added or removed.
  local own: {string: string} = { ["a.tl"] = "da2", ["b.tl"] = "db" }
  assert(first ~= PipelineCheck.keyed("k", true, "a.tl", own, PipelineCheck.whole(own, false)), "a moved pin was not seen")
  local added: {string: string} = { ["b.tl"] = "db" }
  assert(first ~= PipelineCheck.keyed("k", true, "a.tl", added, PipelineCheck.whole(added, false)), "a removed pin was not seen")
  local none: {string: string} = { ["a.tl"] = "da", ["b.tl"] = "db", ["c.tl"] = "dc" }
  assert(PipelineCheck.keyed("k", true, "c.tl", none, PipelineCheck.whole(none, false)) ~=
      PipelineCheck.keyed("k", true, "c.tl", digests, whole), "a pin added for the file was not seen")
end

local function test_the_file_and_its_sources_move_the_key()
  local whole = PipelineCheck.whole(digests, false)
  assert(PipelineCheck.keyed("k1", true, "a.tl", digests, whole) ~= PipelineCheck.keyed("k2", true, "a.tl", digests, whole))
  assert(PipelineCheck.keyed("k", true, "a.tl", digests, whole) ~= PipelineCheck.keyed("k", true, "b.tl", digests, whole))
end

local function test_a_file_the_build_writes_is_keyed_by_every_ceiling()
  local first = PipelineCheck.keyed("k", false, "doc/x.md", digests, PipelineCheck.whole(digests, false))
  local moved: {string: string} = { ["a.tl"] = "da", ["b.tl"] = "db2" }
  assert(first ~= PipelineCheck.keyed("k", false, "doc/x.md", moved, PipelineCheck.whole(moved, false)),
    "a pin moved and a file whose ceilings are kept under another name was not told")
end

local function test_a_tree_with_no_ceilings_is_not_one_with_none_to_raise()
  assert(PipelineCheck.whole(digests, true) ~= PipelineCheck.whole(digests, false))
  assert(PipelineCheck.whole(digests, nil) == PipelineCheck.whole(digests, false))
end
