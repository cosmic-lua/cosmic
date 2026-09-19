local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local observed_reads = require("build.observed_reads")

local function test_call_observes_reads_and_returns_the_value(tmp: string)
  local path = tmp .. "/input"
  assert(Fs.write(path, "hello"))
  local ok, value, reads = observed_reads.call(function(): string
    return assert(Fs.read(path))
  end)
  assert(ok)
  assert(value == "hello")
  assert(reads[1] == path)
end

local function test_call_restores_open_after_an_error(tmp: string)
  local path = tmp .. "/after"
  assert(Fs.write(path, "hello"))
  local original = sys.open
  local ok = observed_reads.call(function()
    error("expected")
  end)
  assert(not ok)
  assert(sys.open == original)
  local later_ok, _, later_reads = observed_reads.call(function()
    assert(Fs.read(path))
  end)
  assert(later_ok)
  assert(#later_reads == 1 and later_reads[1] == path)
end

local function test_join_carries_earlier_reads_to_later_cached_requires()
  local process_reads = { "module-config.txt" }
  local earlier_test_reads = { "helper-config.txt" }
  local first = observed_reads.join(process_reads, earlier_test_reads)
  for _, path in ipairs(earlier_test_reads) do
    process_reads[#process_reads + 1] = path
  end

  -- A later module receiving that helper from require's cache observes no new
  -- opens, but its verdict must still include what initialized the helper.
  local later = observed_reads.join(process_reads, {})
  assert(table.concat(first, ",") == "module-config.txt,helper-config.txt")
  assert(table.concat(later, ",") == "module-config.txt,helper-config.txt")
end
