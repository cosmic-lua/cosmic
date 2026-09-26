--- What a main function returns is the program's exit status, and one it
--- cannot be is refused rather than passed on (core/check.h,
--- `cosmic_tostatus`). A file of its own rather than a case of
--- build/embed_test.tl, which the CI fixtures run as a timed workload.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local embed = require("build.embed")
local exit_status = require("build.exit_status")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

local function run_program(path: string): Child.Result
  return (assert(Child.run({ path }, { env = observations.environment(),
    stdout = "capture", stderr = "capture", timeout_ms = 30000 })))
end

--- An exit keeps only the low byte, so 256 would read as success; and a
--- string, a float or a boolean once raised outside any protected call,
--- which ended the process in a panic. Nothing is 0, and a float with an
--- integer's value, or text naming one, is that integer.
local function test_a_main_that_returns_no_exit_status_is_refused(tmp: string)
  local mains: {string:string} = { big = "256", text = "\"three\"", fits = "7", float = "1.5",
    yes = "true", negative = "-1", whole = "3.0", none = "nil", numeric = "\"5\"" }
  for name, returned in pairs(mains) do
    assert(Fs.mkdirs(tmp .. "/cmd/" .. name))
    assert(Fs.write(tmp .. "/cmd/" .. name .. "/main.tl",
      "return function(): any\n  return " .. returned .. "\nend\n"))
  end
  assert(embed.tree(tmp, true))
  for name, code in pairs({ fits = 7, whole = 3, none = 0, numeric = 5 } as {string:integer}) do
    local r = run_program(tmp .. "/o/bin/" .. name)
    assert(r.code == code, "an exit status that fits is the program's own: " ..
      name .. " exited " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  end
  for _, name in ipairs({ "big", "text", "float", "yes", "negative" }) do
    local r = run_program(tmp .. "/o/bin/" .. name)
    assert(r.code == 2, name .. " exited " .. tostring(r.code) .. ": " .. tostring(r.stderr))
    assert(tostring(r.stderr):find("returned no exit status", 1, true) ~= nil, tostring(r.stderr))
  end
end

--- Text is read as Lua reads a numeral, as `lua_tointegerx` does for
--- the core: space around it, hex and an exponent are allowed.
local function test_status_reads_text_as_the_core_does()
  for value, status in pairs({ [" 3 "] = 3, ["0x3"] = 3, ["3.0"] = 3, ["3e0"] = 3,
      ["255"] = 255 } as {string:integer}) do
    assert(exit_status.status(value) == status, value)
  end
  for _, value in ipairs({ "", "3x", "1.5", "-1", "256", "1e400", "three" }) do
    assert(exit_status.status(value) == nil, value)
  end
end
