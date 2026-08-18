--- Pure tests for _perf.peers.report: markdown rendering, the summary
--- line, and the verdict grammar, all over literal Report fixtures --
--- no peer toolchain, no measurement.

local peers = require("_perf.peers.peers")
local report = require("_perf.peers.report")

local function meta(): peers.PeerMeta
  return {
    timestamp = 0, os = "linux", isa = "x86_64", nproc = 8,
    samples = 5, min_sample_secs = 0.15, runner = "local",
    cosmic_bin = "o/bin/cosmic", cosmic_bin_sha = "deadbeef",
    cosmic_version = "1.2.3",
  }
end

local function measured_row(id: string, label: string, ns: number): peers.Row
  return {
    id = id, label = label, kind = "measured", version = "1.0.0",
    exe = "/usr/bin/" .. id, exe_bytes = 12345, provenance = "prebuilt, on PATH",
    argv = {id, "hello"}, probe_argv = {id, "--version"},
    wall_ns = ns, min_ns = ns - 100, max_ns = ns + 100, spread_pct = 2.5,
    iterations = 87,
  }
end

local function absent_row(id: string, label: string, reason: string): peers.Row
  return {id = id, label = label, kind = "absent", reason = reason}
end

local function full_report(): peers.Report
  return {
    meta = meta(),
    task = "spawn a script that prints perf-hello",
    rows = {
      measured_row("cosmic-lua", "cosmic-lua", 1230000),
      measured_row("cpython", "cpython", 18400000),
      measured_row("node", "node", 31200000),
      measured_row("go", "go", 900000),
    },
  }
end

local function absent_go_report(): peers.Report
  return {
    meta = meta(),
    task = "spawn a script that prints perf-hello",
    rows = {
      measured_row("cosmic-lua", "cosmic-lua", 1230000),
      measured_row("cpython", "cpython", 18400000),
      measured_row("node", "node", 31200000),
      absent_row("go", "go", "go: exec: \"go\": executable file not found in $PATH"),
    },
  }
end

local function test_format_markdown_row_order_preserved()
  local md = report.format_markdown(full_report())
  local pos_cosmic = md:find("cosmic-lua", 1, true)
  local pos_cpython = md:find("cpython", 1, true)
  local pos_node = md:find("node", 1, true)
  local pos_go = md:find("| go ", 1, true)
  assert(pos_cosmic and pos_cpython and pos_node and pos_go,
    "expected all four peer labels in the rendered markdown")
  assert(pos_cosmic < pos_cpython, "cosmic-lua must render before cpython")
  assert(pos_cpython < pos_node, "cpython must render before node")
  assert(pos_node < pos_go, "node must render before go")
end
test_format_markdown_row_order_preserved()

local function test_format_markdown_renders_one_row_per_peer()
  local md = report.format_markdown(full_report())
  assert(md:find("| cosmic-lua |", 1, true), "missing cosmic-lua row")
  assert(md:find("| cpython |", 1, true), "missing cpython row")
  assert(md:find("| node |", 1, true), "missing node row")
  assert(md:find("| go |", 1, true), "missing go row")
end
test_format_markdown_renders_one_row_per_peer()

local function test_format_markdown_with_absent_row()
  local md = report.format_markdown(absent_go_report())
  assert(md:find("| go | absent |", 1, true), "expected an absent go row")
  assert(md:find("go absent:", 1, true), "expected the absent reason listed")
end
test_format_markdown_with_absent_row()

local function test_format_markdown_last_line_is_summary_line()
  local rep = full_report()
  local md = report.format_markdown(rep)
  local last = md:match("([^\n]*)$")
  assert(last == report.summary_line(rep),
    "last line must be the summary line, got: " .. tostring(last))
end
test_format_markdown_last_line_is_summary_line()

local function test_summary_line_all_measured()
  local line = report.summary_line(full_report())
  assert(line:sub(1, 9) == "startup: ", "summary line must start with 'startup: '")
  assert(line:find("cosmic-lua", 1, true), "missing cosmic-lua in summary")
  assert(line:find("go", 1, true), "missing go in summary")
end
test_summary_line_all_measured()

local function test_summary_line_absent_peer()
  local line = report.summary_line(absent_go_report())
  assert(line:find("go absent", 1, true), "expected 'go absent' in summary")
end
test_summary_line_absent_peer()

local function test_verdict_all_measured()
  assert(report.verdict(full_report()) == "peers: OK 4/4 measured")
end
test_verdict_all_measured()

local function test_verdict_one_absent()
  assert(report.verdict(absent_go_report()) == "peers: OK 3/4 measured (absent: go)")
end
test_verdict_one_absent()

local function test_verdict_no_rows_fails()
  local rep: peers.Report = {meta = meta(), task = "unused", rows = {}}
  assert(report.verdict(rep) == "peers: FAIL ()")
end
test_verdict_no_rows_fails()

print("all peers report tests passed")
