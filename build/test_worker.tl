--- One test, run in a process of its own: the other half of
--- `build.test`, which starts this as `cosmic test --worker <root>
--- <module> <test> <tmp> <children> <needs>` and alone records what it
--- reports.
---
--- The worker never opens the build database. It attaches the tree's
--- compiled modules, loads the test's module, calls the one test with
--- its temporary directory, and writes a report to descriptor 3: what
--- the load and the test read, which lines each hit, how long the test
--- took, and whether it passed. Its standard streams are the test's,
--- captured by the runner. A report that is missing or cut short --
--- the test exited the process, crashed it, or ran past its deadline --
--- is itself the runner's answer that the test failed.

local Coverage = require("cosmic.coverage")
local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local observations = require("build.filesystem_observations")
local test_inputs = require("build.test_inputs")
local log = require("build.verdict").log

local record worker
  --- What one worker found, as the runner reads it back.
  record Report
    loaded: boolean
    passed: boolean
    message: string
    elapsed_ns: integer
    load_reads: {observations.Observation}
    test_reads: {observations.Observation}
    load_hits: Coverage.Hits
    test_hits: Coverage.Hits
  end

  --- The descriptor the report is written to.
  report_fd: integer
end

worker.report_fd = 3

local HEADER <const> = "cosmic-test-report-1"

local hex_byte: {string:string} = {}
for byte = 0, 255 do
  hex_byte[string.char(byte)] = string.format("%02x", byte)
end

local function hex(data: string): string
  return (data:gsub(".", hex_byte))
end

local function unhex(data: string): string | nil
  if #data % 2 ~= 0 or data:find("[^0-9a-f]") ~= nil then
    return nil
  end
  return (data:gsub("..", function(byte: string): string
    return string.char(tonumber(byte, 16) or 0)
  end))
end

-- TODO: a report longer than Child's capture limit (16 MB) loses its
-- head, and its test fails as one that never reported: an archive
-- fuzz test's reads overran it under FUZZ_ITERS=2000 while every read
-- of the test's own directory was noted twice, and its extraction
-- property still does past about 5000 (fuzz.yml runs 2000 until this
-- is fixed). So does a test of distinct reads alone: 20000 stats of
-- distinct paths outside the tree, each noted with its resolution,
-- report about 30 MB and fail so, which dropping repeats cannot help.
-- Stream the report, read as it arrives, rather than capture it
-- whole; dropping repeated observations here, as `observations.join`
-- does on the runner's side, shrinks the rest.
local function encode_reads(lines: {string}, tag: string, found: {observations.Observation})
  for _, observation in ipairs(found) do
    lines[#lines + 1] = tag .. " " ..
      observations.key_part(observation.kind, observation.path, observation.answer)
  end
end

local function encode_hits(lines: {string}, tag: string, hits: Coverage.Hits)
  if hits == nil then return end
  local paths: {string} = {}
  for path in pairs(hits) do paths[#paths + 1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do
    local numbers: {integer} = {}
    for line in pairs(hits[path]) do numbers[#numbers + 1] = line end
    table.sort(numbers)
    local text: {string} = {}
    for i, line in ipairs(numbers) do text[i] = tostring(line) end
    lines[#lines + 1] = tag .. " " .. hex(path) .. " " .. table.concat(text, ",")
  end
end

--- Folds into `into` every line the processes the test started wrote
--- into `directory` (see `Coverage.children`), removing each file and
--- then the directory. A file cut short by a process killed mid-write
--- yields the whole lines it holds.
local function child_hits(directory: string, into: Coverage.Hits)
  local names, _ = Fs.list(directory)
  if names ~= nil then
    for _, name in ipairs(names) do
      local file = directory .. "/" .. name
      local text, _ = Fs.read(file)
      if text ~= nil then
        for path, line in text:gmatch("([^\t\n]+)\t(%d+)\n") do
          local here = into[path]
          if here == nil then
            here = {}
            into[path] = here
          end
          local number = math.tointeger(tonumber(line))
          if number ~= nil then here[number] = true end
        end
      end
      local _, _ = Fs.remove(file)
    end
  end
  local _, _ = sys.rmdir(directory)
end

--- The report as text: a header, one line per fact, and a closing line
--- whose absence says the worker never finished writing it.
function worker.encode(report: worker.Report): string
  local lines: {string} = { HEADER,
    "loaded " .. (report.loaded and "1" or "0"),
    "passed " .. (report.passed and "1" or "0"),
    "elapsed " .. tostring(report.elapsed_ns),
    "message " .. hex(report.message),
  }
  encode_reads(lines, "load-read", report.load_reads)
  encode_reads(lines, "test-read", report.test_reads)
  encode_hits(lines, "load-hit", report.load_hits)
  encode_hits(lines, "test-hit", report.test_hits)
  lines[#lines + 1] = "end"
  return table.concat(lines, "\n") .. "\n"
end

--- Reads a report back; nil and why when it is not a whole one.
function worker.decode(text: string): worker.Report | nil, string
  if text == nil or text == "" then return nil, "no report" end
  local report: worker.Report = {
    loaded = false, passed = false, message = "", elapsed_ns = 0,
    load_reads = {}, test_reads = {}, load_hits = {}, test_hits = {},
  }
  local first = true
  local finished = false
  for line in text:gmatch("[^\n]+") do
    if finished then return nil, "text after the end of the report" end
    if first then
      if line ~= HEADER then return nil, "not a test report" end
      first = false
    elseif line == "end" then
      finished = true
    else
      local tag, rest = line:match("^(%S+) ?(.*)$")
      if tag == "loaded" then
        report.loaded = rest == "1"
      elseif tag == "passed" then
        report.passed = rest == "1"
      elseif tag == "elapsed" then
        report.elapsed_ns = math.tointeger(tonumber(rest)) or 0
      elseif tag == "message" then
        report.message = unhex(rest) or ""
      elseif tag == "load-read" or tag == "test-read" then
        local kind, path, answer = rest:match("^(.) ([0-9a-f]*) ([0-9a-f]*)$")
        local decoded_path = path ~= nil and unhex(path) or nil
        local decoded_answer = answer ~= nil and unhex(answer) or nil
        if decoded_path == nil or decoded_answer == nil then
          return nil, "a malformed read: " .. line
        end
        local into = tag == "load-read" and report.load_reads or report.test_reads
        into[#into + 1] = { kind = kind, path = decoded_path, answer = decoded_answer }
      elseif tag == "load-hit" or tag == "test-hit" then
        local path, numbers = rest:match("^([0-9a-f]*) ([0-9,]*)$")
        local decoded = path ~= nil and unhex(path) or nil
        if decoded == nil then return nil, "a malformed hit: " .. line end
        local into = tag == "load-hit" and report.load_hits or report.test_hits
        local per_line: {integer:boolean} = {}
        for number in numbers:gmatch("%d+") do
          per_line[math.tointeger(tonumber(number)) or 0] = true
        end
        into[decoded] = per_line
      else
        return nil, "an unknown line: " .. line
      end
    end
  end
  if first then return nil, "not a test report" end
  if not finished then return nil, "the report was cut short" end
  return report, ""
end

--- Runs the one test the command line names and writes its report.
--- Exits 0 once the report is written, whatever the verdict; anything
--- else means there is no report to read.
--- Installs `runner` as `__runner` on `module`, `cosmic.test`'s table,
--- where `needs` looks for a runner: no member of its type.
local function install(module: any, runner: any)
  if module is {string:any} then module.__runner = runner end
end

--- @param argv `cosmic test --worker <root> <module> <test> <tmp> <children>
--- <needs>`, `children` a directory, not yet there, to collect the
--- coverage of the processes the test starts in, and `needs` what the
--- build read of the module's `cosmic.test` declaration
--- (`test_inputs.canonical`), "" or absent for none: a module whose
--- `needs` call was handed anything else fails to load.
function worker.run(argv: {integer:string}): integer
  local root, module_path, name, tmp = argv[3], argv[4], argv[5], argv[6]
  local children_path = argv[7]
  local expected_needs = argv[8] or ""
  if root == nil or module_path == nil or name == nil or tmp == nil or
      children_path == nil then
    log:complain("test --worker needs a root, a module, a test and two directories")
    return 2
  end
  local attached, attach_trouble = Store.attach(root .. "/o/cosmic.db")
  if not attached then
    log:complain(attach_trouble)
    return 2
  end
  -- The worker's own connection: no test is keyed by all of it (see
  -- `observations.exclude_held_files`; a query of it is the TODO above
  -- core/sqlite.c's `cosmic_sqlite_push_borrowed`).
  observations.exclude_held_files()
  local report: worker.Report = {
    loaded = false, passed = false, message = "", elapsed_ns = 0,
    load_reads = {}, test_reads = {},
  }
  -- Processes the test starts report the core's C they ran here, so it
  -- counts for the test like the C it runs itself.
  local made, _ = sys.mkdir(children_path, 0x1c0)
  local children = made and children_path or nil
  if children ~= nil then Coverage.children(children) end
  local load_session, _ = Coverage.start()
  -- A read outside the tree is resolved as it is read, in case it
  -- names a file of the tree through a link: the test's own directory's
  -- links included.
  local resolving: observations.Resolving = { tree = root, own = { tmp } }
  local resolved_tmp, _ = Fs.absolute(tmp)
  if resolved_tmp ~= nil then resolving.own[#resolving.own + 1] = resolved_tmp end
  -- A confined process writes its coverage beside the test's own.
  if children ~= nil then resolving.own[#resolving.own + 1] = children end
  -- What the module's `needs` call is handed as it loads, through the
  -- hook `cosmic.test` leaves for a runner; once it has loaded, a call
  -- is refused.
  local handed: Test.Needs = nil
  local runner = { loaded = false, handed = function(needs: Test.Needs) handed = needs end }
  install(Test, runner)
  local captured = observations.capture(function(): any
    return require(module_path)
  end, resolving)
  runner.loaded = true
  local loaded, produced, load_reads = captured.ok, captured.produced, captured.reads
  if load_session ~= nil then
    local hits, _ = Coverage.stop(load_session)
    report.load_hits = hits
  end
  report.load_reads = load_reads
  local needs = loaded and test_inputs.canonical(test_inputs.as_declared(handed)) or ""
  if loaded and needs ~= expected_needs then
    loaded = false
    produced = "its cosmic.test needs call was handed what the build did not read " ..
      "from its source -- the build reads only a top-level Test.needs { ... } " ..
      "on a local bound to require(\"cosmic.test\") (see cosmic.test):\n" ..
      "  handed:\n    " .. (needs == "" and "nothing" or needs:gsub("\n", "\n    ")) ..
      "\n  read:\n    " .. (expected_needs == "" and "nothing" or
        expected_needs:gsub("\n", "\n    "))
  end
  report.loaded = loaded
  if not loaded then
    report.message = "the module failed to load: " .. tostring(produced)
  else
    local fn: any = produced is {string: any} and produced[name] or nil
    if not (fn is function(any...): (any...)) then
      report.message = module_path .. " has no test named " .. name
    else
      local test_session, _ = Coverage.start()
      local started = Time.monotonic_ns()
      local run = observations.call(fn, tmp, resolving)
      local finished = Time.monotonic_ns()
      if test_session ~= nil then
        local hits, _ = Coverage.stop(test_session)
        report.test_hits = hits
      end
      report.passed, report.message = run.passed, run.message
      report.test_reads = run.reads
      report.elapsed_ns = finished - started
    end
  end
  if children ~= nil then
    local into = report.test_hits or report.load_hits
    child_hits(children, into or {})
  end
  local written, trouble = Fs.put(worker.report_fd, worker.encode(report))
  if not written then
    log:complain("the test report: " .. trouble)
    return 2
  end
  return 0
end

return worker
