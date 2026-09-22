local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")

local function run(host: string, source: string, caller: string, candidate: string,
    output: string): Child.Result
  local fd = assert(Fs.open_write(output))
  local environment = Env.all()
  environment.COSMIC_CI_SOURCE_ROOT = candidate
  local project = source:match("^(.*)/probe/pass_test%.tl$")
  local result, trouble = Child.run({ "/bin/sh", "-c",
    "cd \"$1\" && exec \"$2\" test \"$3\"", "sh",
    assert(project), host, source }, {
    cwd = caller, env = environment, stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 5000,
  })
  assert(Fs.close(fd))
  return assert(result, trouble)
end

local function test_explicit_host_loads_only_explicit_copied_source(tmp: string)
  local host = assert(Env.get("COSMIC_CI_HOST"), "COSMIC_CI_HOST is required")
  local copied, caller, candidate = tmp .. "/copied", tmp .. "/caller",
    tmp .. "/candidate"
  assert(Fs.mkdirs(copied .. "/probe") and Fs.mkdirs(caller .. "/probe") and
    Fs.mkdirs(candidate .. "/probe"))
  assert(Fs.write(copied .. "/probe/value.tl", "return 'copied'\n"))
  assert(Fs.write(copied .. "/probe/pass_test.tl", [[
local value = require("probe.value")
local function test_copied_source() assert(value == "copied") end
]]))
  assert(Fs.write(caller .. "/probe/value.tl", "error('caller module loaded')\n"))
  assert(Fs.write(caller .. "/probe/pass_test.tl", "error('caller test loaded')\n"))
  assert(Fs.write(candidate .. "/probe/value.tl", "error('candidate module loaded')\n") and
    Fs.write(candidate .. "/probe/pass_test.tl", "error('candidate test loaded')\n"))
  local output = tmp .. "/probe.out"
  assert(run(host, copied .. "/probe/pass_test.tl", caller, candidate, output).ok,
    assert(Fs.read(output)))
  assert(assert(Fs.read(output)):find("1 ran, 0 stood", 1, true),
    "copied test did not execute fresh")
  assert(Fs.write(copied .. "/probe/value.tl", "return 'changed'\n"))
  assert(not run(host, copied .. "/probe/pass_test.tl", caller, candidate,
    tmp .. "/changed.out").ok, "changed copied dependency was ignored")
  assert(assert(Child.run({ "/bin/rm", copied .. "/probe/value.tl" })).ok)
  assert(not run(host, copied .. "/probe/pass_test.tl", caller, candidate,
    tmp .. "/missing.out").ok, "missing copied dependency was ignored")
end
