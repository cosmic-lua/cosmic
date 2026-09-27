--- A sandboxed test's key (build/declared_key.tl): what moves it, what
--- does not, and how little a run reads to compute it.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local declared_key = require("build.declared_key")
local test_inputs = require("build.test_inputs")

--- A tree at `root` holding a module, the module it requires, a
--- declared data directory, and a file nothing declares.
local function tree(root: string)
  assert(Fs.mkdirs(root .. "/suite/data/deeper"))
  assert(Fs.write(root .. "/suite/t_test.tl", "local lib = require('suite.lib')\n"))
  assert(Fs.write(root .. "/suite/lib.tl", "return {}\n"))
  assert(Fs.write(root .. "/suite/data/a.txt", "a\n"))
  assert(Fs.write(root .. "/suite/data/deeper/b.txt", "b\n"))
  assert(Fs.write(root .. "/suite/unrelated.txt", "u\n"))
end

--- The spec of `suite/t_test.tl`'s `test_t` in a tree at `root`, as a
--- run would hand it: its closure, its declared data, and `env`.
local function spec(env?: {string:string}): declared_key.Spec
  local effective: test_inputs.Effective = {
    files = { ["suite/t_test.tl"] = true, ["suite/lib.tl"] = true },
    reads = { "suite/data/" }, host = {}, env = { DECLARED = true }, network = {},
    processes = false, tool = false, store = false, caches = {}, cache_paths = {},
  }
  return {
    id = "suite.t_test test_t", group = "suite.t_test", module_key = "module",
    runtime = "runtime sandboxed", compiler = "compiler",
    declaration = 'reads "suite/data/"\nenv "DECLARED"', effective = effective,
    environment = env or { DECLARED = "d", TMPDIR = "/tmp" },
  }
end

local function key_of(root: string, s?: declared_key.Spec): string
  return declared_key.compute(declared_key.digests(root), s or spec())
end

--- Nothing declared changed: the same key, in a run of its own, and in
--- another checkout of the same content at another path -- a key names
--- nothing of where the tree is, a variable's value that is a path of
--- it included.
local function test_a_key_is_the_same_while_nothing_declared_changes(tmp: string)
  tree(tmp .. "/one")
  tree(tmp .. "/two")
  local one, two = assert(Fs.absolute(tmp .. "/one")), assert(Fs.absolute(tmp .. "/two"))
  assert(key_of(one) == key_of(one))
  assert(key_of(one) == key_of(two))
  assert(key_of(one, spec({ DECLARED = one .. "/suite", TMPDIR = "/tmp" })) ==
    key_of(two, spec({ DECLARED = two .. "/suite", TMPDIR = "/tmp" })))
end

--- A file of the tree nothing declares, and the host's caches, are no
--- part of it.
local function test_an_undeclared_file_does_not_move_it(tmp: string)
  tree(tmp)
  local before = key_of(tmp)
  assert(Fs.write(tmp .. "/suite/unrelated.txt", "changed\n"))
  assert(Fs.write(tmp .. "/elsewhere.txt", "new\n"))
  local s = spec()
  s.effective.cache_paths = { tmp .. "/cache" }
  assert(Fs.mkdirs(tmp .. "/cache"))
  assert(Fs.write(tmp .. "/cache/entry", "x"))
  assert(key_of(tmp, s) == before)
end

--- Each thing it is a digest of moves it: a declared file's contents,
--- one added beneath a declared directory, a file's mode, a module of
--- the closure, the declaration, a variable's value, the runtime (the
--- core), the compiler, the module's key and the test's name.
local function test_each_input_moves_it(tmp: string)
  tree(tmp)
  local seen: {string:string} = {}
  local function differs(what: string, s?: declared_key.Spec)
    local key = key_of(tmp, s)
    assert(seen[key] == nil, what .. " keys as " .. tostring(seen[key]) .. " did")
    seen[key] = what
  end
  differs("the start")
  assert(Fs.write(tmp .. "/suite/data/deeper/b.txt", "B\n"))
  differs("a declared file's contents")
  assert(Fs.write(tmp .. "/suite/data/c.txt", ""))
  differs("a file added beneath a declared directory")
  assert(sys.chmod(tmp .. "/suite/data/c.txt", 493)) -- 0o755
  differs("a declared file's mode")
  assert(Fs.symlink("a.txt", tmp .. "/suite/data/link"))
  differs("a link beneath a declared directory")
  assert(Fs.write(tmp .. "/suite/lib.tl", "return { changed = true }\n"))
  differs("a module of the closure")
  local s = spec()
  s.declaration = s.declaration .. "\ntool true"
  differs("the declaration", s)
  differs("a variable's value", spec({ DECLARED = "e", TMPDIR = "/tmp" }))
  differs("a variable given", spec({ DECLARED = "d", TMPDIR = "/tmp", OTHER = "" }))
  s = spec()
  s.runtime = "another core sandboxed"
  differs("the runtime", s)
  s = spec()
  s.compiler = "another compiler"
  differs("the compiler", s)
  s = spec()
  s.module_key = "another module"
  differs("the module's key", s)
  s = spec()
  s.id = "suite.t_test test_u"
  differs("the test's name", s)
  s = spec()
  s.effective.host = { tmp .. "/host.txt" }
  differs("a host path, missing", s)
  assert(Fs.write(tmp .. "/host.txt", "h\n"))
  differs("a host file, there", s)
  assert(Fs.write(tmp .. "/host.txt", "H\n"))
  differs("a host file's contents", s)
  assert(Fs.remove(tmp .. "/suite/lib.tl"))
  differs("a module of the closure gone")
end

--- A test that declares the network has no key; one that declares none
--- does.
local function test_a_test_that_reaches_the_network_has_no_key()
  local s = spec()
  assert(declared_key.keyable(s.effective))
  s.effective.network = { ["127.0.0.1"] = true }
  assert(not declared_key.keyable(s.effective))
end

--- A file is read once to be hashed: a later look, in the same run or,
--- through what `kept` answers, in another, whose `lstat` says the same
--- reads nothing; one rewritten is read again.
local function test_a_file_hashed_once_is_not_read_again(tmp: string)
  tree(tmp)
  -- Settled, as a file a run remembers must be: older than a rewrite
  -- within its timestamp's tick could go unseen.
  for _, file in ipairs({ "suite/t_test.tl", "suite/lib.tl", "suite/data/a.txt",
                          "suite/data/deeper/b.txt" }) do
    assert(sys.utimensat(tmp .. "/" .. file, 1000000000, 0, 1000000000, 0))
  end
  local digests = declared_key.digests(tmp)
  local first = declared_key.compute(digests, spec())
  assert(digests.read == 4, tostring(digests.read))
  assert(declared_key.compute(digests, spec()) == first)
  assert(digests.read == 4, tostring(digests.read))
  local later = declared_key.digests(tmp, nil, declared_key.kept(digests))
  assert(declared_key.compute(later, spec()) == first)
  assert(later.read == 0, tostring(later.read))
  assert(Fs.write(tmp .. "/suite/lib.tl", "return 1\n"))
  assert(declared_key.compute(later, spec()) ~= first)
  assert(later.read == 1, tostring(later.read))
end

--- While frozen, a run's keys look at each input once, for every test
--- of its selection; thawed, a key looks again, so one computed after
--- a test ran sees what changed while it did.
local function test_a_frozen_run_looks_once_and_a_thawed_one_again(tmp: string)
  tree(tmp)
  local digests = declared_key.digests(tmp)
  declared_key.freeze(digests)
  local before = declared_key.compute(digests, spec())
  assert(Fs.write(tmp .. "/suite/data/a.txt", "changed while it ran\n"))
  assert(declared_key.compute(digests, spec()) == before)
  declared_key.thaw(digests)
  assert(declared_key.compute(digests, spec()) ~= before)
end
