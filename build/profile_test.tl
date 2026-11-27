--- `cosmic profile` (build/profile.tl), run in this process on profiles held in memory: what each list adds up, the
--- spans' tree, folded stacks, and what it refuses. build/profile_tool_test.tl profiles a real run and reads it.

local lua_tail = require("build.lua_tail")
local profile = require("build.profile")

--- A profile of process `pid` (parent 1) with these span and sample lines.
local function file(pid: integer, lines: {string}): string
  return ("cosmic-profile 1\nprocess %d parent 1 clock cpu hz 997\ncommand cosmic -e x\n"):format(pid) ..
    ("total wall_ns 9000000 cpu_ns %d sampled_us 6000 dropped_us 0 other_us 0 peak_rss_kb 2048\n"):format(pid * 1000000) ..
    table.concat(lines, "\n") .. "\n"
end

local A <const> = file(10, {
  "span [outer] 1 8000000 5000000 1024",
  "span [outer];[inner] 2 4000000 3000000 1024",
  "sample [outer];[inner];main@x:1;spin@x:3 x:4 3000",
  "sample [outer];main@x:1;string.find@[C] x:2 2000",
  "sample main@x:1;spin@x:3;spin@x:3 x:4 1000",
})
local B <const> = file(20, { "span [outer] 1 1000000 1000000 1024", "sample main@x:1 x:1 500" })

local record Ran
  mut code: integer
  mut out: string
  mut err: string
end

--- Runs `cosmic profile` on `words`, with `files` as the files there are, and `dirs` the directories (each named
--- by its path, holding the names listed), and `chunk` what holds a module's bytecode.
local function run(words: {string}, files: {string: string}, dirs?: {string: {string}},
                   chunk?: function(name: string): string?): Ran
  local argv: mut {string} = { "profile" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local ran: Ran = { code = -1, out = "", err = "" }
  ran.code = profile.run(argv, {
    out = function(text: string): boolean, string
      ran.out = ran.out .. text
      return true, ""
    end,
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
    read = function(path: string): string?, string
      local text = files[path]
      if text == nil then return nil, path .. ": no such file" end
      return text, ""
    end,
    list = function(path: string): {string}?
      if dirs == nil then return nil end
      return dirs[path]
    end,
    chunk = chunk or function(_: string): string? return nil end,
  })
  return ran
end

local function test_it_reads_a_profile_file()
  local p = assert(profile.read(A, "a.prof"))
  assert(p.pid == 10 and p.parent == 1 and p.clock == "cpu" and p.hz == 997 and p.command == "cosmic -e x")
  assert(p.cpu_ns == 10000000 and p.sampled_us == 6000 and #p.spans == 2 and #p.samples == 3)
  local s = assert(p.samples[1])
  assert(#s.frames == 4 and s.frames[1] == "[outer]" and s.line == "x:4" and s.us == 3000)
  local none, why = profile.read("hello\n", "h.prof")
  assert(none == nil and why:find("h.prof: not a profile", 1, true) ~= nil, why)
end

--- Own time is the innermost function's, spans left out; time in the stack counts a function once a sample.
local function test_own_time_and_stack_time()
  local ran = run({ "--by", "function", "a.prof" }, { ["a.prof"] = A })
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.out:find("own time, of 6.0 ms sampled:\n", 1, true) == 1, ran.out)
  assert(ran.out:find(" 66.67%%%s+4.0 ms  spin@x:3\n") ~= nil, ran.out)
  assert(ran.out:find(" 33.33%%%s+2.0 ms  string.find@%[C%]\n") ~= nil, ran.out)
  local stack = run({ "--by", "stack", "a.prof" }, { ["a.prof"] = A })
  assert(stack.out:find("100.00%%%s+6.0 ms  main@x:1\n") ~= nil, stack.out)
  assert(stack.out:find(" 66.67%%%s+4.0 ms  spin@x:3\n") ~= nil, stack.out)
  assert(stack.out:find("[outer]", 1, true) == nil, stack.out)
  local lines = run({ "--by", "line", "--top", "1", "a.prof" }, { ["a.prof"] = A })
  assert(lines.out == "lines, of 6.0 ms sampled:\n 66.67%       4.0 ms  x:4\n", lines.out)
end

--- Spans add up across files by path, each under the span it stood in.
local function test_spans_add_up_under_their_parents()
  local ran = run({ "--by", "span", "a.prof", "b.prof" }, { ["a.prof"] = A, ["b.prof"] = B })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "spans (count, wall, cpu, most heap at a close):\n  [outer]  2  9.0 ms  6.0 ms  1.0 MB\n" ..
      "    [inner]  2  4.0 ms  3.0 ms  1.0 MB\n", ran.out)
end

--- A directory stands for its `.prof` files; `--process` keeps one; the processes list puts most CPU first.
local function test_a_directory_and_one_process()
  local files = { ["d/10.prof"] = A, ["d/20.prof"] = B, ["d/notes.txt"] = "x" }
  local dirs = { d = { "10.prof", "20.prof", "notes.txt" } }
  local all = run({ "--by", "process", "d" }, files, dirs)
  assert(all.code == 0, all.err)
  assert(all.out == "processes (pid, parent, cpu, sampled, peak resident set, command):\n" ..
      "  20  1  20.0 ms  6.0 ms  2.0 MB  cosmic -e x\n  10  1  10.0 ms  6.0 ms  2.0 MB  cosmic -e x\n", all.out)
  local one = run({ "--by", "process", "--process", "10", "d" }, files, dirs)
  assert(one.out == "processes (pid, parent, cpu, sampled, peak resident set, command):\n" ..
      "  10  1  10.0 ms  6.0 ms  2.0 MB  cosmic -e x\n", one.out)
  local missing = run({ "--process", "30", "d" }, files, dirs)
  assert(missing.code == 5 and missing.err:find("no profile of process 30", 1, true) ~= nil, missing.err)
end

--- The report with no `--by` has the totals, the spans and both lists; an empty file counts as killed.
local function test_the_whole_report()
  local ran = run({ "a.prof", "e.prof" }, { ["a.prof"] = A, ["e.prof"] = "" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("^1 process, 10.0 ms cpu, 6.0 ms sampled on the cpu clock, the longest 9.0 ms wall, " ..
      "the largest peak resident set 2.0 MB, 1 empty %(killed by a signal%)\n\nspans") ~= nil, ran.out)
  assert(ran.out:find("\n\nown time, of 6.0 ms", 1, true) ~= nil, ran.out)
  assert(ran.out:find("\n\nin the stack, of 6.0 ms", 1, true) ~= nil, ran.out)
end

--- Folded stacks keep the spans and add up equal stacks.
local function test_folded_stacks()
  local twice = A .. "sample [outer];main@x:1;string.find@[C] x:2 2000\n"
  local ran = run({ "--folded", "a.prof" }, { ["a.prof"] = twice })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "[outer];[inner];main@x:1;spin@x:3 3000\n[outer];main@x:1;string.find@[C] 4000\n" ..
      "main@x:1;spin@x:3;spin@x:3 1000\n", ran.out)
end

local function test_refusals_and_bad_files()
  local none = run({}, {})
  assert(none.code == 2 and none.err:find("cosmic: profile: name a profile directory", 1, true) ~= nil, none.err)
  local both = run({ "--folded", "--by", "line", "a.prof" }, { ["a.prof"] = A })
  assert(both.code == 2 and both.err:find("--folded prints stacks alone", 1, true) ~= nil, both.err)
  local kind = run({ "--by", "nope", "a.prof" }, { ["a.prof"] = A })
  assert(kind.code == 2, kind.err)
  local missing = run({ "nowhere.prof" }, {})
  assert(missing.code == 5 and missing.err:find("nowhere.prof: no such file", 1, true) ~= nil, missing.err)
  local bad = run({ "bad.prof" }, { ["bad.prof"] = "cosmic-profile 1\nsample x\n" })
  assert(bad.code == 5 and bad.err:find("a sample line it cannot read", 1, true) ~= nil, bad.err)
end

--- A sample with no frame (`-`) is charged to "(no frame)"; a span whose parent no line names still sorts under
--- that parent, before a later span.
local function test_a_frameless_sample_and_a_missing_parent()
  local text = file(30, { "span [a];[b] 1 1000000 1000000 1024", "span [z] 1 1000000 1000000 1024", "span [a];[c] 1 1000 1000 1024",
    "sample - x:1 100" })
  local own = run({ "--by", "function", "f.prof" }, { ["f.prof"] = text })
  assert(own.out:find("100.00%%%s+0.1 ms  %(no frame%)\n") ~= nil, own.out)
  local folded = run({ "--folded", "f.prof" }, { ["f.prof"] = text })
  assert(folded.out == "(no frame) 100\n", folded.out)
  local spans = run({ "--by", "span", "f.prof" }, { ["f.prof"] = text })
  assert(spans.out:find("    %[b%].*\n    %[c%].*\n  %[z%]") ~= nil, spans.out)
end

--- A module's load is a `[require:<module>]` span: the report's span tree leaves it out, `--by span` keeps it,
--- `--by require` lists the modules by wall time, and [`profile.loaded`] names them.
local function test_module_loads_are_spans_of_their_own()
  local text = file(40, { "span [main] 1 9000000 9000000 2048", "span [main];[require:a] 1 6000000 5000000 1024",
    "span [main];[require:a];[require:b] 1 2000000 2000000 512", "sample [main];m@x:1 x:1 100" })
  local whole = run({ "r.prof" }, { ["r.prof"] = text })
  assert(whole.out:find("\n  [main]  1  9.0 ms  9.0 ms  2.0 MB\n\n", 1, true) ~= nil, whole.out)
  assert(whole.out:find("require:", 1, true) == nil, whole.out)
  local spans = run({ "--by", "span", "r.prof" }, { ["r.prof"] = text })
  assert(spans.out:find("      [require:b]  1", 1, true) ~= nil, spans.out)
  local modules = run({ "--by", "require", "r.prof" }, { ["r.prof"] = text })
  assert(modules.out == "modules loaded (2; wall, cpu, with what each required):\n" ..
      "        6.0 ms        5.0 ms  a\n        2.0 ms        2.0 ms  b\n", modules.out)
  local read = assert(profile.read(text, "r.prof"))
  local loaded = profile.loaded({ read })
  assert(loaded["a"] == true and loaded["b"] == true and loaded["main"] == nil)
end

--- `--per-process` puts a row under each span for each process that closed one, most CPU first.
local function test_spans_per_process()
  local ran = run({ "--by", "span", "--per-process", "a.prof", "b.prof" }, { ["a.prof"] = A, ["b.prof"] = B })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "spans (count, wall, cpu, most heap at a close):\n  [outer]  2  9.0 ms  6.0 ms  1.0 MB\n" ..
      "    | 1  8.0 ms  5.0 ms  a.prof  -e x\n    | 1  1.0 ms  1.0 ms  b.prof  -e x\n" ..
      "    [inner]  2  4.0 ms  3.0 ms  1.0 MB\n      | 2  4.0 ms  3.0 ms  a.prof  -e x\n", ran.out)
end

--- `--against` sets each span's time beside an older run's; a span the older run had not is new.
local function test_spans_against_an_older_run()
  local files = { ["a.prof"] = A, ["b.prof"] = B }
  local ran = run({ "--by", "span", "--against", "b.prof", "a.prof" }, files)
  assert(ran.code == 0, ran.err)
  assert(ran.out == "spans against the older run (wall then -> now, change; cpu then -> now, change):\n" ..
      "  [outer]  1.0 ms -> 8.0 ms  +700.0%;  1.0 ms -> 5.0 ms  +400.0%\n" ..
      "    [inner]  0.0 ms -> 4.0 ms  new;  0.0 ms -> 3.0 ms  new\n", ran.out)
  local back = run({ "--by", "span", "--against", "a.prof", "b.prof" }, files)
  assert(back.out:find("    [inner]  4.0 ms -> 0.0 ms  -100.0%;", 1, true) ~= nil, back.out)
  local refused = run({ "--by", "function", "--against", "b.prof", "a.prof" }, files)
  assert(refused.code == 2 and refused.err:find("--against compares the spans", 1, true) ~= nil, refused.err)
  local split = run({ "--per-process", "--against", "b.prof", "a.prof" }, files)
  assert(split.code == 2 and split.err:find("not --per-process", 1, true) ~= nil, split.err)
  -- `--process` keeps a process of this run; the older run is read whole.
  local one = run({ "--by", "span", "--process", "10", "--against", "b.prof", "a.prof" }, files)
  assert(one.code == 0 and one.out:find("[outer]  1.0 ms -> 8.0 ms", 1, true) ~= nil, one.out .. one.err)
  local missing = run({ "--against", "old.prof", "a.prof" }, files)
  assert(missing.code == 5 and missing.err:find("old.prof: no such file", 1, true) ~= nil, missing.err)
end

--- A frame or line of a chunk numbered by instruction (past 1 << 24) is placed at its source line through the
--- build's bytecode of the module, and names the instruction `#k` where there is none.
local function test_numbered_frames_are_placed_at_source_lines()
  local source = "local x = 1\nlocal function f()\n  local y = x + 1\n  return y\nend\nreturn f\n"
  local bytecode = assert(lua_tail.bytecode_of(source, "m", "m.lua"))
  local defines = assert(lua_tail.defined_lines(bytecode, "m"))
  local lines = assert(lua_tail.instruction_lines(bytecode, "m"))
  local k: integer = assert(next(defines))
  assert(defines[k] == 2, tostring(defines[k]))
  -- The first instruction of f, whose body opens on line 3.
  local j = k + 1
  assert(lines[j] == 3, tostring(lines[j]))
  local base = 1 << 24
  local text = file(10, { ("sample main@m:0;f@m:%d m:%d 1000"):format(base + k, base + j) })
  local ran = run({ "--by", "function", "a.prof" }, { ["a.prof"] = text }, nil, function(name: string): string?
    if name == "m" then return bytecode end
    return nil
  end)
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("  f@m:2\n", 1, true) ~= nil, ran.out)
  local line = run({ "--by", "line", "a.prof" }, { ["a.prof"] = text }, nil, function(_: string): string?
    return bytecode
  end)
  assert(line.out:find("  m:3\n", 1, true) ~= nil, line.out)
  local unplaced = run({ "--by", "function", "a.prof" }, { ["a.prof"] = text })
  assert(unplaced.out:find(("  f@m:#%d\n"):format(k), 1, true) ~= nil, unplaced.out)
end
