--- Worked examples for [`cosmic.sandbox`], shown by `cosmic docs` and run by
--- `cosmic test`.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local sys = require("cosmic.sys")

local Example = {}

--- A policy read from JSON is checked as it is read: a letter out of
--- order, or a key the policy does not have, is a failure naming the
--- field by its JSON Pointer, never a program that runs with more than
--- its author meant.
function Example.decode()
  local policy = assert(Sandbox.decode('{"env":["HOME"],"grants":[{"path":"data","letters":"rx"}],"tmp":true}'))
  print(policy.env[1], policy.grants[1].letters, policy.tmp) -- HOME  rx  true
  assert(policy.env[1] == "HOME" and policy.grants[1].letters == "rx" and policy.tmp)
  local bad, why = Sandbox.decode('{"grants":[{"path":"data","letters":"xr"}]}')
  print(why) -- sandbox: pointer "/grants/0/letters": "xr" is not in the order of "rwxcu", each letter once: "rx"
  assert(bad == nil and why:find("/grants/0/letters", 1, true), why)
  local unknown, trouble = Sandbox.decode('{"network":true}')
  assert(unknown == nil and trouble:find("/network", 1, true), trouble)
end

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

--- A merged policy as canonical text, the same for the same policy, for
--- a key or a report: a variable set shows as a digest, so the text shows
--- that its value changed and not what it is, and decoding the text gives a
--- policy that encodes to it again.
function Example.encode()
  local merged = assert(Sandbox.merge({ promises = { "jit", "fork" }, set_env = { TOKEN = "s3cret" } }))
  local text = Sandbox.encode(merged)
  print(text) -- {"promises":["fork","jit"],"set_env_digests":{"TOKEN":"..."}}
  assert(text:find('"promises":["fork","jit"]', 1, true) and not text:find("s3cret", 1, true))
  assert(Sandbox.encode((assert(Sandbox.decode(text)))) == text)
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
  print(why) -- sandbox: unknown profile "everything" (known: cosmic, system)
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
