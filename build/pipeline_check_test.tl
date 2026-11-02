--- [`build.pipeline_check`]: the pipeline held against the checks of the tree. A module over the limit on the locals of its
--- main chunk is refused with its file and count, from the pipeline and from the memo alike.
local Fs = require("cosmic.fs")
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
