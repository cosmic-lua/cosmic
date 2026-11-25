--- Worked examples for [`cosmic.sandbox`], shown by `cosmic docs` and run by
--- `cosmic test`.

local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")
local sys = require("cosmic.sys")

local Example = {} -- checked: literal_needs_type

--- Two policies joined: the letters of a path are summed in the order of
--- "rwxcu", the lists are unions without repeats, and two different
--- values for one limit are refused -- here, naming the limit, not the
--- policies.
function Example.union()
  local reads: Sandbox.Policy = { grants = { { path = "/srv", letters = "r" }, { calls = "fork" } } }
  local runs: Sandbox.Policy = { grants = { { path = "/srv", letters = "x" }, { calls = "jit" }, { calls = "fork" } } }
  local both = assert(Sandbox.union(reads, runs))
  local grant = assert(Sandbox.paths(both)[1])
  print(grant.letters, table.concat(Sandbox.calls(both), ",")) -- rx  fork,jit
  assert(grant.letters == "rx" and table.concat(Sandbox.calls(both), ",") == "fork,jit")
  local clash, why = Sandbox.union({ limits = { open_files = 64 } }, { limits = { open_files = 128 } })
  print(why) -- sandbox: $.limits.open_files: given two values, 64 and 128
  assert(clash == nil)
  assert(why:find("limits.open_files", 1, true), why)
end

--- A profile's grants as a policy: "system" is what a host's programs read, and a profile named in `profiles` is
--- resolved by [`Sandbox.union`].
function Example.profile()
  local system = assert(Sandbox.profile("system"))
  local grant = assert(Sandbox.paths(system)[1])
  print(grant.path, grant.letters) -- /usr  r
  local merged = assert(Sandbox.union({ profiles = { "system" } }))
  local held = false
  for _, joined in ipairs(Sandbox.paths(merged)) do
    if joined.path == grant.path then held = true end
  end
  assert(merged.profiles == nil and held)
  local none, why = Sandbox.profile("everything")
  print(why) -- sandbox: unknown profile "everything" (known: proc, programs, system)
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

return Example -- checked: export_not_declared
