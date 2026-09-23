--- What a main function returns is the program's exit status, and one it
--- cannot be is refused rather than passed on (core/check.h,
--- `cosmic_tostatus`). A file of its own rather than a case of
--- build/embed_test.tl, which the CI fixtures run as a timed workload.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local embed = require("build.embed")

local function run_program(path: string): Child.Result
  return (assert(Child.run({ path }, { stdout = "capture", stderr = "capture",
    timeout_ms = 30000 })))
end

--- An exit keeps only the low byte, so 256 would read as success; and a
--- string once raised outside any protected call, which ended the process
--- in a panic.
local function test_a_main_that_returns_no_exit_status_is_refused(tmp: string)
  for name, returned in pairs({ big = "256", text = "\"three\"", fits = "7" }) do
    assert(Fs.mkdirs(tmp .. "/cmd/" .. name))
    assert(Fs.write(tmp .. "/cmd/" .. name .. "/main.tl",
      "return function(): any\n  return " .. returned .. "\nend\n"))
  end
  assert(embed.tree(tmp, true))
  local fits = run_program(tmp .. "/o/bin/fits")
  assert(fits.code == 7, "an exit status that fits is the program's own: " .. tostring(fits.code))
  for _, name in ipairs({ "big", "text" }) do
    local r = run_program(tmp .. "/o/bin/" .. name)
    assert(r.code == 2, name .. " exited " .. tostring(r.code) .. ": " .. tostring(r.stderr))
    assert(tostring(r.stderr):find("returned no exit status", 1, true) ~= nil, tostring(r.stderr))
  end
end
