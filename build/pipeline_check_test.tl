--- The key a module's answer of the pipeline check is kept under ([`build.pipeline_check`]): it holds the ceilings of the
--- module's own file and no other's, so a stale answer is never served for a pin that moved, and a pin elsewhere costs nothing.
local Fs = require("cosmic.fs")
local PipelineCheck = require("build.pipeline_check")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local importer = require("build.importer")
local work = require("build.work")

Test.policy{}

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

--- A module of `count` locals, each read by the table it returns.
local function locals_module(count: integer): string
  local names: mut {string} = {}
  local lines: mut {string} = {}
  for index = 1, count do
    local name = "v" .. tostring(index)
    names[#names + 1] = name
    lines[#lines + 1] = "local " .. name .. " = " .. tostring(index)
  end
  return table.concat(lines, "\n") .. "\nreturn { " .. table.concat(names, ", ") .. " }\n"
end

local function test_a_module_over_the_limit_on_main_locals_is_refused_with_its_file_and_count(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/wide.tl", locals_module(181)))
  assert(Fs.write(root .. "/edge.tl", locals_module(180)))
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  assert(importer.derive(handle))
  local rows: {PipelineCheck.Row} = {
    { file = "wide.tl", module = "wide", dialect = "tl", key = "kw", plain = true },
    { file = "edge.tl", module = "edge", dialect = "tl", key = "ke", plain = true },
  }
  local memo = assert(Sqlite.open(tmp .. "/memo.db", { writable = true }))
  local function compare(): {string}
    return PipelineCheck.compare(root, handle.db, memo, #rows, function(index: integer): PipelineCheck.Row
      return assert(rows[index])
    end, {}, {})
  end
  local function told(lines: {string}): string
    return table.concat(lines, "\n")
  end
  -- Asked of the pipeline: the module over the limit is refused with its file and count, the one at it is not.
  local first = compare()
  assert(#first == 1, told(first))
  assert(assert(first[1]):find("^wide%.tl: the main chunk of its Lua holds 181 locals, over 180 "), told(first))
  -- Answered from the memo: the same.
  local second = compare()
  assert(told(second) == told(first), told(second))
  -- An entry that says no count is asked again, and the count is not 0.
  assert(Sqlite.run(memo, "UPDATE check_memo SET value = 'N M x' WHERE kind = 'pipeline' AND value LIKE '% M %'"))
  local third = compare()
  assert(told(third) == told(first), told(third))
  assert(work.close(handle))
end
