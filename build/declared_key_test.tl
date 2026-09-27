--- A sandboxed test's key (build/declared_key.tl): what moves it, what
--- does not, and how little a run reads to compute it.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local artifact = require("build.artifact")
local declared_key = require("build.declared_key")
local test_inputs = require("build.test_inputs")
local Test = require("cosmic.test")

--- What the host's identity reads (`declared_key.host_identity`), on
--- whichever system this is, what the host says of itself, and a file a
--- link leads out of the tree to.
Test.needs{
  host = { "/etc/os-release", "/etc/passwd", "/lib/apk/db/installed", "/proc/",
    "/usr/lib/os-release", "/usr/lib/sysimage/rpm/", "/var/lib/dpkg/status", "/var/lib/rpm/" },
  env = { "COSMIC_HOST_ID" },
}

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
    runtime = "runtime sandboxed", compiler = "compiler", host = "host",
    declaration = 'reads "suite/data/"\nenv "DECLARED"', effective = effective,
    environment = env or { DECLARED = "d", TMPDIR = "/tmp" },
  }
end

local function key_of(root: string, s?: declared_key.Spec): string
  local key, why = declared_key.compute(declared_key.digests(root), s or spec())
  assert(key ~= nil, why)
  return key
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
  -- Every part of a PATH-like value, not only its first.
  assert(key_of(one, spec({ DECLARED = "/usr/bin:" .. one .. "/o/bin:" .. one .. "/bin",
    TMPDIR = "/tmp" })) == key_of(two, spec({ DECLARED = "/usr/bin:" .. two .. "/o/bin:" ..
    two .. "/bin", TMPDIR = "/tmp" })))
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
  assert(Fs.symlink("../../lib.tl", tmp .. "/suite/data/deeper/up"))
  differs("a link beneath a declared directory to a file of the tree")
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
  s.host = "another host"
  differs("the host", s)
  s = spec()
  s.harness = "another harness"
  differs("the harness every worker runs", s)
  -- A worker that may run the program undeclared keys it as declared.
  s = spec()
  s.runs_tool = true
  differs("the tool, run where it could not be refused", s)
  s = spec()
  s.runs_tool = true
  s.program = "another program"
  differs("the program that runs, for one that runs the tool", s)
  s = spec()
  s.closure_store = "one address"
  differs("the store of the closure, given", s)
  s = spec()
  s.closure_store = "another address"
  differs("the store of the closure's address", s)
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
--- does, and so does one that declares only loopback hosts, which its
--- worker, offline, reaches on a loopback of its own.
local function test_a_test_that_reaches_the_network_has_no_key()
  local s = spec()
  assert(declared_key.keyable(s.effective))
  s.effective.network = { ["example.com"] = true }
  assert(not declared_key.keyable(s.effective))
  s.effective.network = { ["*"] = true }
  assert(not declared_key.keyable(s.effective))
  s.effective.network = { ["127.0.0.1"] = true, ["example.com"] = true }
  assert(not declared_key.keyable(s.effective))
  s.effective.network = { ["127.0.0.1"] = true, ["127.0.0.2"] = true, ["::1"] = true,
    ["localhost"] = true }
  assert(declared_key.keyable(s.effective))
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
  local later = declared_key.digests(tmp, declared_key.kept(digests))
  assert(declared_key.compute(later, spec()) == first)
  assert(later.read == 0, tostring(later.read))
  assert(Fs.write(tmp .. "/suite/lib.tl", "return 1\n"))
  assert(declared_key.compute(later, spec()) ~= first)
  assert(later.read == 1, tostring(later.read))
end

--- A file rewritten in place, its size and modification time set back
--- as they were (`touch -r`, `cp -p`), is read again: its change time
--- moved, which no write can set back.
local function test_a_rewrite_with_its_time_set_back_is_read_again(tmp: string)
  tree(tmp)
  local file = tmp .. "/suite/data/a.txt"
  assert(sys.utimensat(file, 1000000000, 0, 1000000000, 0))
  local digests = declared_key.digests(tmp)
  local first = declared_key.compute(digests, spec())
  local later = declared_key.digests(tmp, declared_key.kept(digests))
  local fd = assert(sys.open(file, sys.O_WRONLY))
  assert(sys.write(fd, "b\n") == 2)
  assert(sys.close(fd))
  assert(sys.utimensat(file, 1000000000, 0, 1000000000, 0))
  assert(declared_key.compute(later, spec()) ~= first, "a stale digest answered")
end

--- A link beneath a declared directory that leads out of the tree --
--- where a sandbox finds what it leads to, if it was given that -- has
--- no key: its test runs every time, and why is said. One that leads
--- within the tree, or nowhere out of it, is keyed.
local function test_a_link_out_of_the_tree_has_no_key(tmp: string)
  tree(tmp .. "/root")
  local root = tmp .. "/root"
  assert(Fs.write(tmp .. "/outside.txt", "o\n"))
  assert(Fs.symlink("../../../../outside.txt", root .. "/suite/data/deeper/out"))
  local key, why = declared_key.compute(declared_key.digests(root), spec())
  assert(key == nil and why:find("leads out of the tree", 1, true), why)
  assert(Fs.remove(root .. "/suite/data/deeper/out"))
  assert(Fs.symlink("/etc/passwd", root .. "/suite/data/abs"))
  key, why = declared_key.compute(declared_key.digests(root), spec())
  assert(key == nil and why:find("/etc/passwd", 1, true), why)
  -- Dangling, and absolute: out of the tree by what it says.
  assert(Fs.remove(root .. "/suite/data/abs"))
  assert(Fs.symlink("/nowhere/at/all", root .. "/suite/data/abs"))
  key, why = declared_key.compute(declared_key.digests(root), spec())
  assert(key == nil and why:find("/nowhere/at/all", 1, true), why)
  assert(Fs.remove(root .. "/suite/data/abs"))
  assert(Fs.symlink("../../lib.tl", root .. "/suite/data/deeper/in"))
  assert(key_of(root) ~= nil)
end

--- The host's identity is the same from one look to the next, and says
--- something: at least the user and the kernel.
local function test_the_host_identity_is_stable(tmp: string)
  local digests = declared_key.digests(tmp)
  local one = declared_key.host_identity(digests)
  assert(#one == 64 and one == declared_key.host_identity(digests), one)
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

--- The harness's digest holds every module its roots require, directly
--- or not, by source: a change to one moves it, as a change to the
--- worker's sandbox would; a module outside that closure does not.
local function test_a_harness_module_moves_the_harness(tmp: string)
  local imports: {string:{string}} = {
    ["build.test"] = { "build.test_sandbox", "cosmic.fs" },
    ["build.test_worker"] = { "build.filesystem_observations" },
    ["build.test_sandbox"] = { "build.caches" },
  }
  local sources: {string:string} = {
    ["build.test"] = "t", ["build.test_worker"] = "w", ["build.test_sandbox"] = "s",
    ["build.caches"] = "c", ["cosmic.fs"] = "f", ["build.filesystem_observations"] = "o",
    ["build.docs"] = "d",
  }
  local roots = { "build.test", "build.test_worker" }
  local before = declared_key.harness(roots, sources, imports)
  sources["build.docs"] = "d2"
  assert(declared_key.harness(roots, sources, imports) == before, "outside the closure")
  for _, name in ipairs({ "build.test_sandbox", "build.caches", "build.filesystem_observations",
                          "cosmic.fs" }) do
    local was = sources[name]
    sources[name] = was .. "2"
    assert(declared_key.harness(roots, sources, imports) ~= before, name)
    sources[name] = was
  end
  -- An unrelated test's key moves with it.
  tree(tmp)
  local s = spec()
  s.harness = before
  local key = key_of(tmp, s)
  sources["build.test_sandbox"] = "s2"
  s = spec()
  s.harness = declared_key.harness(roots, sources, imports)
  assert(key_of(tmp, s) ~= key)
end

--- A key holds the compiler's identity only where the test's closure
--- holds a module that reads it: two runs of a test whose closure reads
--- none, under compilers of two identities that made the same bytecode
--- -- the same store, the same harness -- share a key.
local function test_only_a_closure_that_reads_the_compiler_is_keyed_by_it(tmp: string)
  local reader = declared_key.compiler_readers[1]
  assert(declared_key.reads_compiler({ "suite.lib", reader, "suite.t_test" }))
  assert(not declared_key.reads_compiler({ "suite.lib", "suite.t_test" }))
  assert(not declared_key.reads_compiler({}))
  tree(tmp)
  local function run_under(compiler: string, closure: {string}): string
    local s = spec()
    s.closure_store = "the same store"
    s.compiler = declared_key.reads_compiler(closure) and compiler or ""
    return key_of(tmp, s)
  end
  local plain = { "suite.lib", "suite.t_test" }
  assert(run_under("one compiler", plain) == run_under("another compiler", plain))
  local reading = { reader, "suite.t_test" }
  assert(run_under("one compiler", reading) ~= run_under("another compiler", reading))
end

--- Each part of the host's identity moves it: its kernel, the
--- processor's features, the status of this process, the user, which
--- /proc a sandbox gets, and what the host says of itself; the
--- processor's features are each counted once, and only those a core
--- chooses code by. Its package database and the system it says it is
--- move what it has installed (`system_identity`) instead, and not it.
local function test_each_part_of_the_host_moves_its_identity(tmp: string)
  local function write(name: string, text: string): string
    assert(Fs.write(tmp .. "/" .. name, text))
    return tmp .. "/" .. name
  end
  local sources: declared_key.HostSources = {
    packages = { write("packages", "p1") },
    system = { write("os", "o1"), write("release", "r1"), write("version", "v1") },
    cpuinfo = write("cpuinfo", "flags : aes fma\nflags : fma aes\n"), machine = "x86_64",
    status = write("status", "Name: x\nCapEff: 0\nUid: 1 1 1 1\n"),
    own_proc = true, host_id = "h1", uid = 1,
  }
  local function identity(): string
    return declared_key.host_identity(declared_key.digests(tmp), sources)
  end
  local seen: {string:string} = {}
  local function differs(what: string)
    local id = identity()
    assert(seen[id] == nil, what .. " identifies as " .. tostring(seen[id]) .. " did")
    seen[id] = what
  end
  differs("the start")
  assert(identity() == identity(), "the same host")
  write("cpuinfo", "flags : fma aes avx512f\n")
  assert(seen[identity()] == "the start", "each feature is counted once, if a core reads it")
  local installed = declared_key.system_identity(declared_key.digests(tmp), sources)
  write("packages", "p2")
  write("os", "o2")
  assert(seen[identity()] == "the start", "what the host has installed moved it")
  local now = declared_key.system_identity(declared_key.digests(tmp), sources)
  assert(now ~= installed, "the packages and the system moved nothing installed")
  write("packages", "p3")
  assert(declared_key.system_identity(declared_key.digests(tmp), sources) ~= now, "the packages")
  write("release", "r2")
  differs("the kernel's release")
  write("version", "v2")
  differs("the kernel's version")
  write("cpuinfo", "flags : aes\n")
  assert(seen[identity()] == "the kernel's version", "a feature no core reads")
  write("cpuinfo", "flags : aes fma pclmulqdq\n")
  differs("a feature of the processor")
  write("status", "Name: x\nCapEff: 1\nUid: 1 1 1 1\n")
  differs("the capabilities")
  write("status", "Name: y\nCapEff: 1\nUid: 1 1 1 1\n")
  assert(seen[identity()] == "the capabilities", "a field it does not key")
  sources.own_proc = false
  differs("which /proc a sandbox gets")
  sources.host_id = "h2"
  differs("what the host says of itself")
  sources.uid = 2
  differs("the user")
end

--- Two hosts that differ only in what they have installed -- their
--- package databases and the systems they say they are -- key a test
--- alike where its module is given none of the system's paths, and
--- where it names a file of the host's, keyed by its contents; apart
--- where it declares `system`, or a directory of the host's, which is
--- keyed by its name alone and stands on what is installed.
local function test_only_a_module_given_the_system_is_keyed_by_what_is_installed(tmp: string)
  tree(tmp .. "/tree")
  assert(Fs.mkdirs(tmp .. "/host/dir"))
  assert(Fs.write(tmp .. "/host/file", "f\n"))
  local function installed(packages: string, release: string): string
    assert(Fs.write(tmp .. "/packages", packages))
    assert(Fs.write(tmp .. "/os-release", release))
    return declared_key.system_identity(declared_key.digests(tmp), {
      packages = { tmp .. "/packages" }, system = { tmp .. "/os-release" },
    })
  end
  local one = installed("dpkg one\n", "ID=one\n")
  local other = installed("dpkg other\n", "ID=other\n")
  assert(one ~= other)
  local function key_on(system: string, declares_system: boolean, host: {string}): string
    local s = spec()
    s.system = system
    s.effective.system = declares_system
    s.effective.host = host
    return key_of(tmp .. "/tree", s)
  end
  assert(key_on(one, false, {}) == key_on(other, false, {}), "a module not given the system")
  assert(key_on(one, false, { tmp .. "/host/file" }) == key_on(other, false, { tmp .. "/host/file" }),
    "a module given a file of the host's")
  assert(key_on(one, false, { "/proc/" }) == key_on(other, false, { "/proc/" }),
    "a module given /proc, which no package installs")
  assert(key_on(one, true, {}) ~= key_on(other, true, {}), "a module given the system")
  assert(key_on(one, false, { tmp .. "/host/dir" }) ~= key_on(other, false, { tmp .. "/host/dir" }),
    "a module given a directory of the host's")
  assert(key_on(one, true, {}) ~= key_on(one, false, {}), "declaring the system")
end

--- The program's identity is its files' contents, but for the stamp
--- that says its core was verified, which a first run makes.
local function test_the_program_is_keyed_by_its_contents(tmp: string)
  assert(Fs.write(tmp .. "/program", "one"))
  local digests = declared_key.digests(tmp)
  local before = declared_key.program_identity(digests, { tmp .. "/program" })
  assert(Fs.write(tmp .. "/program", "two"))
  local now = declared_key.program_identity(digests, { tmp .. "/program" })
  assert(now ~= before)
  assert(Fs.write(tmp .. "/.verified-core", "stamp"))
  assert(declared_key.program_identity(digests, { tmp .. "/program", tmp .. "/.verified-core" }) ==
    now, "the stamp moved it")
end

--- A program as an artifact lays it out (`artifact.host_program`),
--- written to `path`: `core` ahead of a database carrying `meta` and
--- one module, `cosmic.thing`, whose bytecode is `bytecode`.
local function program_at(path: string, core: string, meta: {string:string}, bytecode: string)
  local db_path = path .. ".db"
  local _, _ = Fs.remove(db_path)
  local db = assert(Sqlite.open(db_path, true))
  assert(db:exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL); " ..
    "CREATE TABLE modules (path TEXT PRIMARY KEY, bytecode BLOB NOT NULL)"))
  local keys: {string} = {}
  for key in pairs(meta) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    assert(Sqlite.run(db, "INSERT INTO meta (key, value) VALUES (?1, ?2)",
      { { text = key }, { text = meta[key] } }))
  end
  assert(Sqlite.run(db, "INSERT INTO modules (path, bytecode) VALUES ('cosmic.thing', ?1)",
    { { blob = bytecode } }))
  assert(db:close())
  local database = assert(Fs.read(db_path))
  assert(Fs.remove(db_path))
  local bytes = assert(artifact.host_program({ bytes = core, target_id = 1,
    configuration_id = 1, digest = Hash.sha256(core) }, database))
  local _, _ = Fs.remove(path)
  assert(Fs.write(path, bytes))
  assert(sys.chmod(path, 493)) -- 0o755
end

--- A program is keyed by what it runs as: its image and the rows it
--- carries, but not the rows of its `meta` every edit of the tree
--- moves -- `boot_hash`, over every file of the tool's trees, its tests'
--- included, and `projected`, over the whole projection -- so a tool
--- rebuilt for a comment in a test keys as it did, in the program that
--- runs and in o/bin alike, while a carried module and the core move
--- both.
local function test_a_program_is_keyed_by_what_it_runs_as(tmp: string)
  tree(tmp)
  assert(Fs.mkdirs(tmp .. "/o/bin"))
  local root = assert(Fs.absolute(tmp))
  local tool = root .. "/o/bin/cosmic"
  local s = spec()
  s.effective.tool = true
  local function keys(): string, string
    s.program = declared_key.program_identity(declared_key.digests(root), { tool })
    return s.program, key_of(root, s)
  end
  local meta: {string:string} = { boot_hash = "one", projected = "one", writer = "w", compiler = "c" }
  program_at(tool, "core one", meta, "bytecode one")
  local program, key = keys()
  -- Rebuilt for an edit no binary carries: its bytes move, not its key.
  local bytes = assert(Fs.read(tool))
  meta.boot_hash, meta.projected = "two", "two"
  program_at(tool, "core one", meta, "bytecode one")
  assert(assert(Fs.read(tool)) ~= bytes, "the rebuilt program's bytes did not move")
  local rebuilt_program, rebuilt_key = keys()
  assert(rebuilt_program == program, "boot_hash and projected moved the program")
  assert(rebuilt_key == key, "boot_hash and projected moved the key")
  -- Any other row of its meta does.
  meta.writer = "another writer"
  program_at(tool, "core one", meta, "bytecode one")
  local writer_program, writer_key = keys()
  assert(writer_program ~= program and writer_key ~= key, "the writer left the key")
  meta.writer = "w"
  -- A carried module.
  program_at(tool, "core one", meta, "bytecode two")
  local module_program, module_key = keys()
  assert(module_program ~= program and module_program ~= writer_program,
    "a carried module left the program")
  assert(module_key ~= key and module_key ~= writer_key, "a carried module left the key")
  -- The image: the core ahead of the database.
  program_at(tool, "core two", meta, "bytecode one")
  local image_program, image_key = keys()
  assert(image_program ~= program and image_program ~= module_program,
    "the image left the program")
  assert(image_key ~= key and image_key ~= module_key, "the image left the key")
  -- A text's bytes after a NUL, which quote() would end it at.
  meta.note = "a\0one"
  program_at(tool, "core one", meta, "bytecode one")
  local one_program = keys()
  meta.note = "a\0two"
  program_at(tool, "core one", meta, "bytecode one")
  assert(keys() ~= one_program, "a text's bytes after a NUL left the program")
  meta.note = nil
  -- A file in o/bin that is no artifact is keyed by its contents.
  program_at(tool, "core one", meta, "bytecode one")
  assert(select(2, keys()) == key)
  assert(Fs.write(root .. "/o/bin/other", "one"))
  local other = select(2, keys()) as string
  assert(other ~= key, "a file added to o/bin left the key")
  assert(Fs.write(root .. "/o/bin/other", "two"))
  assert(select(2, keys()) ~= other, "a file of o/bin's contents left the key")
end

--- What runs an artifact's core is keyed for every test of a run the
--- artifact starts, whether it runs the program or not: a launcher,
--- manifest or core ahead of the database moves a key that declares no
--- `tool`, while a carried row, which such a test's key holds by its
--- own closure, does not; a host program's run holds none.
local function test_an_artifacts_launcher_moves_every_key(tmp: string)
  tree(tmp)
  local root = assert(Fs.absolute(tmp))
  local path = root .. "/cosmic-portable"
  local meta: {string:string} = { writer = "w", compiler = "c" }
  local function launcher(): string
    return declared_key.launcher_identity(declared_key.digests(root), path)
  end
  program_at(path, "launcher and core one", meta, "bytecode one")
  local one = launcher()
  program_at(path, "launcher and core one", meta, "bytecode two")
  assert(launcher() == one, "a carried row moved the launcher")
  program_at(path, "launcher and core two", meta, "bytecode one")
  local two = launcher()
  assert(two ~= one, "the head left the launcher")
  local s = spec()
  assert(not s.effective.tool)
  local native = key_of(root, s)
  s.launcher = one
  local first = key_of(root, s)
  s.launcher = two
  local second = key_of(root, s)
  assert(first ~= native and second ~= first, "the launcher left a key without `tool`")
  assert(declared_key.launcher_identity(declared_key.digests(root), root .. "/nowhere") ==
    "missing")
end

--- A module keyed by its own source (`own`) moves the harness when its
--- source does, not when what it imports does -- unless a root reaches
--- it, when its closure is walked as any other.
local function test_an_own_module_is_keyed_by_its_source_alone()
  local imports: {string:{string}} = {
    ["build.test_worker"] = { "build.caches" },
    ["build.test"] = { "build.importer" },
    ["build.writer"] = { "build.schema" },
  }
  local sources: {string:string} = {
    ["build.test_worker"] = "w", ["build.caches"] = "c", ["build.test"] = "t",
    ["build.importer"] = "i", ["build.writer"] = "r", ["build.schema"] = "s",
  }
  local roots = { "build.test_worker" }
  local own = { "build.test", "build.writer" }
  local function digest(): string return declared_key.harness(roots, sources, imports, own) end
  local before = digest()
  sources["build.caches"] = "c2"
  assert(digest() ~= before, "a root's closure")
  sources["build.caches"] = "c"
  sources["build.test"] = "t2"
  assert(digest() ~= before, "an own module's source")
  sources["build.test"] = "t"
  sources["build.importer"] = "i2"
  assert(digest() == before, "what an own module imports")
  -- Reached from a root, an own module's closure is walked.
  imports["build.test_worker"] = { "build.caches", "build.writer" }
  local reached = digest()
  sources["build.schema"] = "s2"
  assert(digest() ~= reached, "an own module a root reaches")
end

--- The store a worker is given at o/cosmic.db: the whole projection by
--- its contents where the module declares `store`, and the store of its
--- closure by its address where it does not -- so a projection moved by
--- an edit outside the closure moves only the first.
local function test_the_store_given_is_keyed_as_it_is_given(tmp: string)
  tree(tmp)
  assert(Fs.mkdirs(tmp .. "/o"))
  assert(Fs.write(tmp .. "/o/cosmic.db", "one"))
  local closed = spec()
  closed.closure_store = "address"
  local whole = spec()
  whole.effective.store = true
  whole.closure_store = "address"
  local closed_before, whole_before = key_of(tmp, closed), key_of(tmp, whole)
  assert(Fs.write(tmp .. "/o/cosmic.db", "two"))
  assert(key_of(tmp, closed) == closed_before, "the projection moved a closure store's key")
  assert(key_of(tmp, whole) ~= whole_before, "the projection left a declared store's key")
end
