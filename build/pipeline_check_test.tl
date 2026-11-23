--- Tests of [`build.pipeline_check`], the pipeline held against the checks of the tree. A module over the limit on the locals of its
--- main chunk is refused with its file and count, from the pipeline and from the memo alike.
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local fanout = require("build.compile_fanout")
local PipelineCheck = require("build.pipeline_check")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local importer = require("build.importer")
local work = require("build.work")

Test.policy{}

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
    { file = "wide.tl", module = "wide", dialect = "tl", key = "kw" },
    { file = "edge.tl", module = "edge", dialect = "tl", key = "ke" },
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

--- A module the tree's checks refuse for an error no marker holds, and the pipeline accepts, is told with both sides: the two
--- read one program, and a difference is the finding.
local function test_a_module_the_tree_refuses_and_the_pipeline_accepts_is_told(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/fine.tl", "local record Fine\nend\nreturn Fine\n"))
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  assert(importer.derive(handle))
  local rows: {PipelineCheck.Row} = { { file = "fine.tl", module = "fine", dialect = "tl", key = "kf" } }
  local told = PipelineCheck.compare(root, handle.db, nil, #rows, function(index: integer): PipelineCheck.Row
    return assert(rows[index])
  end, { "fine.tl: 1 error of not_assignable in its bodies on line 1, marked 0; follow the fix above rather than add a marker" }, {})
  local text = table.concat(told, "\n")
  assert(text:find("fine.tl: the tree checks refuse it for an error no marker holds, and the pipeline accepts it", 1, true) ~= nil,
    text)
  assert(work.close(handle))
end

--- Copies of the process ([`build.compile_fanout`]) answer what the process answers alone: the same lines, and the same
--- answers kept in the memo.
local function test_copies_of_the_process_answer_as_the_process_does(tmp: string)
  if Proc.cpu_count() < 2 then
    Test.skip("this host has one processor, for which no copy is forked")
  end
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  local rows: mut {PipelineCheck.Row} = {}
  for index = 1, 6 do
    local name = "m" .. tostring(index)
    assert(Fs.write(root .. "/" .. name .. ".tl", locals_module(176 + index)))
    rows[#rows + 1] = { file = name .. ".tl", module = name, dialect = "tl", key = "k" .. name }
  end
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  assert(importer.derive(handle))
  local least, meminfo = fanout.least, fanout.meminfo
  local function compare(copied: boolean): string, string
    fanout.least = if copied then 1 else 1000000 end
    fanout.meminfo = "MemAvailable: 67108864 kB\n"
    local memo = assert(Sqlite.memory())
    local lines = PipelineCheck.compare(root, handle.db, memo, #rows, function(index: integer): PipelineCheck.Row
      return assert(rows[index])
    end, {}, {})
    local kept: mut {string} = {}
    local found = assert(Sqlite.text_rows(memo,
      "SELECT key || '=' || value FROM check_memo WHERE kind = 'pipeline' ORDER BY key"))
    for _, row in ipairs(found) do
      kept[#kept + 1] = row:text(1)
    end
    assert(memo:close())
    return table.concat(lines, "\n"), table.concat(kept, "\n")
  end
  local alone, alone_kept = compare(false)
  local ended = fanout.ended_well
  local copied, copied_kept = compare(true)
  assert(fanout.ended_well > ended, "no copy did the work")
  fanout.least, fanout.meminfo = least, meminfo
  assert(alone:find("m6.tl: the main chunk of its Lua holds 182 locals", 1, true) ~= nil and
      alone:find("m4.tl", 1, true) == nil, alone)
  assert(copied == alone, "the copies told:\n" .. copied .. "\nthe process:\n" .. alone)
  assert(copied_kept == alone_kept, "the copies kept:\n" .. copied_kept .. "\nthe process:\n" .. alone_kept)
  assert(work.close(handle))
end
