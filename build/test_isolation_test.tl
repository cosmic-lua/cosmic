--- A worker's own side of running each test apart, in this process:
--- the directory it is handed, reached through a link, and the report
--- it writes back, read whole or not at all.
--- build/test_isolation_tool_test.tl holds the runs of `cosmic test`
--- that end a hung or exiting test alone.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local test = require("build.test")
local test_sandbox = require("build.test_sandbox")
local worker = require("build.test_worker")

--- A test's directory is reached through a link, so a path resolved on
--- one side of a comparison and not the other fails here as it does
--- under macOS's /var; the one this test itself was handed is too.
--- It is as long as macOS's is, sandboxed or not, so a bound on a
--- path's length is met on every host.
local function test_a_test_directory_is_reached_through_a_link(tmp: string)
  assert(#tmp >= test_sandbox.scratch_length + #"/tmp", tmp)
  local st = assert(sys.lstat(tmp))
  assert(st.kind == "link", tmp .. " is a " .. st.kind)
  local resolved = assert(Fs.absolute(tmp))
  assert(resolved ~= tmp, resolved)
  assert(Fs.is_dir(resolved))
  local scratch = assert(test.scratch())
  assert(assert(Fs.absolute(scratch)) == scratch, scratch)
  assert(#scratch >= test_sandbox.scratch_length, scratch)
  assert(assert(Fs.readlink(scratch .. "/tmp")) == "real")
  assert(assert(Fs.absolute(scratch .. "/tmp")) == scratch .. "/real")
  assert(Fs.remove_tree(scratch))
end

local function test_a_report_reads_back_whole_or_not_at_all()
  local report: worker.Report = {
    loaded = true, passed = false, message = "line one\nline two", elapsed_ns = 42,
    load_reads = { { kind = "o", path = "a b\n", answer = "" } },
    test_reads = { { kind = "e", path = "HOME", answer = "ok /root" } },
    load_hits = { ["x.y"] = { [3] = true, [1] = true } },
    test_hits = {},
  }
  local text = worker.encode(report)
  local back = assert(worker.decode(text))
  assert(back.loaded and not back.passed and back.elapsed_ns == 42)
  assert(back.message == "line one\nline two")
  assert(back.load_reads[1].path == "a b\n" and back.load_reads[1].kind == "o")
  assert(back.test_reads[1].answer == "ok /root")
  assert(back.load_hits["x.y"][1] and back.load_hits["x.y"][3])
  local cut, trouble = worker.decode(text:sub(1, #text - 5))
  assert(cut == nil and trouble == "the report was cut short")
  assert(worker.decode("") == nil)
  assert(worker.decode("something else\nend\n") == nil)
  assert(worker.decode(text .. "extra\n") == nil)
end
