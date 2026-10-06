--- [`Fs.read`] of a file that says nothing true of its size, as /proc's do:
--- a host with a /proc (`requires`). The rest of its cases are in
--- cosmic/fs_test.tl.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy{ requires = { "proc" } }

--- A file of /proc, whose size is 0, is read whole, in chunks.
local function test_read_takes_a_file_that_says_nothing_true_of_its_size()
  local text = assert(Fs.read("/proc/self/status"))
  assert(text:find("SigIgn:", 1, true) ~= nil, text)
end
