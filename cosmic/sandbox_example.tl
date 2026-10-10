--- Worked examples for [`cosmic.sandbox`], shown by `cosmic docs` and run by
--- `cosmic test`.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local sys = require("cosmic.sys")

local Example = {}

--- Two policies joined: the letters of a path are summed in the order of
--- "rwxcu", the lists are unions without repeats, and two different
--- values for one limit are refused -- here, naming the limit, not the
--- policies.
function Example.merge()
  local reads: Sandbox.Policy = { grants = { { path = "/srv", letters = "r" } }, promises = { "fork" } }
  local runs: Sandbox.Policy = { grants = { { path = "/srv", letters = "x" } }, promises = { "jit", "fork" } }
  local both = assert(Sandbox.merge(reads, runs))
  print(both.grants[1].letters, table.concat(both.promises, ",")) -- rx  fork,jit
  assert(both.grants[1].letters == "rx" and table.concat(both.promises, ",") == "fork,jit")
  local clash, why = Sandbox.merge({ limits = { open_files = 64 } }, { limits = { open_files = 128 } })
  print(why) -- sandbox: limits.open_files is given two values, 64 and 128
  assert(clash == nil and why:find("limits.open_files", 1, true), why)
end

--- A profile's grants as a policy: "cosmic" is this program's own
--- executable, read and run, and a profile named in `profiles` is
--- resolved by `merge`.
function Example.profile()
  local cosmic = assert(Sandbox.profile("cosmic"))
  assert(cosmic.grants[1].path == assert(Proc.executable()) and cosmic.grants[1].letters == "rx")
  local merged = assert(Sandbox.merge({ profiles = { "cosmic" } }))
  assert(merged.profiles == nil and merged.grants[1].path == cosmic.grants[1].path)
  local none, why = Sandbox.profile("everything")
  print(why) -- sandbox: unknown profile "everything" (known: cosmic, proc, system)
  assert(none == nil)
end

--- What a program needs read and run to start, as real paths: itself, then
--- the interpreter of its `#!` line or its ELF header. A policy that does not
--- grant each of these `r` and `x` does not start the program.
function Example.loaders()
  local dir = assert(sys.realpath((assert(Fs.mkdtemp("cosmic-sandbox-example-")))))
  assert(Fs.write(dir .. "/interpreter", "not a program"))
  assert(Fs.write(dir .. "/script", "#!" .. dir .. "/interpreter\necho hi\n"))
  local files = assert(Sandbox.loaders(dir .. "/script"))
  print(table.concat(files, "\n")) -- <dir>/script, then <dir>/interpreter
  assert(#files == 2 and files[1] == dir .. "/script" and files[2] == dir .. "/interpreter")
  assert(Fs.remove_tree(dir))
end

return Example
