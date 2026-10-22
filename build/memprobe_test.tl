--- Tests of [`build.memprobe`]: a mark writes one line of numbers when the probe is on, and nothing when it is off.
local Memprobe = require("build.memprobe")
local Test = require("cosmic.test")

Test.policy{ profiles = { "proc" } }

local function test_a_mark_is_one_line_with_the_label_and_the_sizes_when_the_probe_is_on()
  local told: {string} = {}
  local sink = Memprobe.sink
  local enabled = Memprobe.enabled
  Memprobe.enabled = true
  Memprobe.sink = function(line: string)
    told[#told + 1] = line
  end
  local line = Memprobe.mark("a phase")
  Memprobe.sink = sink
  Memprobe.enabled = enabled
  assert(line ~= nil and #told == 1 and told[1] == line, tostring(line))
  assert(line:match("^MEM a phase +[%d%.]+s rss= *%d+MB peak= *%d+MB heap= *%d+MB live= *%d+MB$") ~= nil, line)
end

local function test_a_mark_does_nothing_when_the_probe_is_off()
  local told: {string} = {}
  local sink = Memprobe.sink
  local enabled = Memprobe.enabled
  Memprobe.enabled = false
  Memprobe.sink = function(line: string)
    told[#told + 1] = line
  end
  local line = Memprobe.mark("a phase")
  Memprobe.sink = sink
  Memprobe.enabled = enabled
  assert(line == nil and #told == 0)
end
