--- `cosmic fix` writes the checker's rewrites ([`build.fix.rewrites`]) into a file of a project the build refused, with
--- what it requires from the project, and builds again. It declares `tool` because it starts this program.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

--- The program itself, which its test starts.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function fix(root: string, args: {string}): string
  local words: mut {string} = { "fix" }
  for _, a in ipairs(args) do words[#words + 1] = a end
  local started = Test.cosmic(words, { cwd = root, stdout = "capture", stderr = "stdout",
    timeout_ns = Clock.seconds(120) })
  return assert((assert(Child.run(started.argv, started.options))).stdout)
end

local OTHER <const> = "local record other\nend\n\n--- Answers one.\nfunction other.thing(): integer\n  return 1\nend\n\n" ..
  "return other\n"

local USER <const> = "local Other = require(\"other\")\n\nlocal n = Other.thing()\nprint(\"n=\" .. n)\n" ..
  "print(\"m=\" .. n) -- checked: concat_type\n"

--- The run tells each rewrite and writes it; a finding a marker holds is left. `--check` writes nothing.
local function test_a_refused_file_gets_the_checkers_rewrites(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/user.tl", USER))
  local checked = fix(root, { "--check", "user.tl" })
  assert(checked:find("fix: would rewrite user.tl:4:15: concat_type: `n` -> `tostring(n)`", 1, true), checked)
  local unchanged, _ = Fs.read(root .. "/user.tl")
  assert(unchanged == USER, "a check writes nothing")
  local out = fix(root, { "user.tl" })
  assert(out:find("fix: rewrote user.tl:4:15: concat_type: `n` -> `tostring(n)`", 1, true), out)
  local text = assert(Fs.read(root .. "/user.tl"))
  assert(text:find("print(\"n=\" .. tostring(n))\n", 1, true) and text:find("print(\"m=\" .. n) -- checked: concat_type\n", 1,
    true), text)
end

--- A file whose errors all have a rewrite builds once they are written: the run passes.
local function test_a_file_put_right_by_its_rewrites_builds(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/user.tl", "local Other = require(\"other\")\n\nlocal n = Other.thing()\nprint(\"n=\" .. n)\n"))
  local out = fix(root, { "user.tl" })
  assert(out:find("fix: rewrote user.tl:4:15", 1, true) ~= nil, out)
  assert(out:find("refused", 1, true) == nil and out:find("FAIL", 1, true) == nil, out)
  local again = fix(root, { "--check", "user.tl" })
  assert(again:find("rewrite", 1, true) == nil and again:find("FAIL", 1, true) == nil, again)
end
