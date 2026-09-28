--- A sandboxed test's key (build/declared_key.tl): what moves it, what
--- does not, and how little a run reads to compute it.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local analyzer = require("build.analyzer")
local artifact = require("build.artifact")
local core_image = require("build.core_image")
local declared_key = require("build.declared_key")
local fixture = require("build.core_image_fixture")
local teal = require("build.teal")
local test_inputs = require("build.test_inputs")
local Test = require("cosmic.test")

--- What the host's identity reads (`declared_key.host_identity`), on
--- whichever system this is, what the host says of itself, and a file a
--- link leads out of the tree to.
Test.needs{
  host = { "/etc/os-release", "/etc/passwd", "/lib/apk/db/installed", "/proc/",
    "/usr/lib/os-release", "/usr/lib/sysimage/rpm/", "/var/lib/dpkg/status", "/var/lib/rpm/" },
  env = { "COSMIC_HOST_ID", "COSMIC_SYSTEM_ID" },
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
    epoch = 1, timeout_ms = 30000,
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
  s.epoch = 2
  differs("the harness's epoch", s)
  s = spec()
  s.timeout_ms = 60000
  differs("the timeout its worker runs under", s)
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

--- The fields of `record`, a record `module` declares (`Spec`,
--- `Effective`), as the build's catalog of its docs lists them
--- (`build.analyzer`, which fills o/cosmic.db's `docs`), in the order
--- the source declares them: read off the module's source, so a field
--- added to the record is listed here with no edit to this test. A
--- field whose type is a record (or a map of them) the walk does not
--- enter gets one coarse change, not one per field of its own: walk
--- such a record here as `Effective` is.
local function fields_of(module: string, record: string): {string}
  local built = assert(teal.load())
  local source = assert(Store.source(module))
  local analysis = assert(analyzer.analyze(built, source, module))
  local out: {string} = {}
  for _, entry in ipairs(analysis.docs) do
    local name = entry.symbol:match("^" .. record:gsub("%.", "%%.") .. "%.([%w_]+)$")
    if name ~= nil and entry.kind == "field" then out[#out + 1] = name end
  end
  assert(#out > 0, module .. " declares no fields of " .. record)
  return out
end

--- A change to one field of a populated value, and what it holds
--- apart from the populated value (`from`), where one field is keyed
--- only as another says (`program` only for a test that runs the
--- tool): the key of `from`'s value and of `change`'s after it differ.
local record Change<T>
  from: function(T)
  change: function(T)
end

--- Whether `value` holds something: not nil, false, "" or empty.
local function populated(value: any): boolean
  if value == nil or value == false or value == "" then return false end
  if value is table then return next(value) ~= nil end
  return true
end

--- Every field `fields` lists, of the record `holder` finds in a value,
--- is held by `changes`, each of which must move `key` from the value
--- `make` builds, or named in `unkeyed`, with why no key needs it;
--- `make`'s value populates every field, and
--- neither table names a field the record no longer declares. `what`
--- names the record in what fails.
local function each_field_moves<T>(what: string, fields: {string}, make: function(): T,
                                   holder: function(T): any, key: function(T): string,
                                   changes: {string:Change<T>}, unkeyed: {string:string})
  local declared: {string:boolean} = {}
  for _, name in ipairs(fields) do
    declared[name] = true
    local full = holder(make()) as {string:any}
    assert(populated(full[name]), what .. "." .. name .. " is not populated: set it in " ..
      "the populated value, to a value other than its default")
    local change = changes[name]
    if change == nil then
      assert(unkeyed[name] ~= nil, what .. "." .. name .. " is neither changed nor named " ..
        "unkeyed: add a change of it that must move the key, or, where a key need not " ..
        "hold it, say why in `unkeyed`")
    else
      assert(unkeyed[name] == nil, what .. "." .. name .. " is both changed and unkeyed")
      local value = make()
      if change.from ~= nil then change.from(value) end
      local before = key(value)
      assert(key(value) == before, what .. "'s key is not the same twice")
      change.change(value)
      assert(key(value) ~= before, "a change to " .. what .. "." .. name ..
        " left the key: a field of the record that the key leaves out")
    end
  end
  for name in pairs(changes) do
    assert(declared[name], what .. " declares no field " .. name .. " that a change names")
  end
  for name in pairs(unkeyed) do
    assert(declared[name], what .. " declares no field " .. name .. " that unkeyed names")
  end
end

--- A spec each field of which, and of its `effective`, holds something,
--- of a test in a tree as `tree` writes it: its module runs the tool,
--- declares `store` and the system, and names a host file in `hostdir`,
--- outside the tree, by a variable (`$H/host.txt`).
local function full_spec(hostdir: string): declared_key.Spec
  assert(Fs.mkdirs(hostdir))
  assert(Fs.write(hostdir .. "/host.txt", "h\n"))
  local effective: test_inputs.Effective = {
    files = { ["suite/t_test.tl"] = true, ["suite/lib.tl"] = true },
    reads = { "suite/data/" }, host = { hostdir .. "/host.txt" },
    env = { DECLARED = true, H = true }, network = { ["127.0.0.1"] = true },
    processes = true, tool = true, store = true, system = true,
    caches = { "zig" }, cache_paths = { hostdir .. "/cache" },
    variables = { "DECLARED", "H" }, named = { H = true },
    spelled = { [hostdir .. "/host.txt"] = "$H/host.txt" }, located = { H = hostdir },
    unresolved = "no reason",
  }
  return {
    id = "suite.t_test test_t", group = "suite.t_test", module_key = "module",
    runtime = "runtime sandboxed", compiler = "compiler", epoch = 1, timeout_ms = 30000,
    program = "program", host = "host", system = "system", launcher = "launcher",
    declaration = 'reads "suite/data/"\nenv "DECLARED"', effective = effective,
    environment = { DECLARED = "d", H = hostdir, TMPDIR = "/tmp" },
    runs_tool = true, closure_store = "address",
  }
end

--- Every field of a spec (`declared_key.Spec`), and of its effective
--- inputs (`test_inputs.Effective`), moves the key, but those named
--- with why no key needs them: the fields are the records' own, as the
--- catalog lists them, so a field added to either and left out of the
--- key fails here.
local function test_every_field_of_a_spec_moves_it(tmp: string)
  local root, hostdir = tmp .. "/tree", tmp .. "/hostdir"
  tree(root)
  local function key(s: declared_key.Spec): string return key_of(root, s) end
  local function append(field: string): Change<declared_key.Spec>
    return { change = function(s: declared_key.Spec)
      local t = s as {string:any}
      t[field] = (t[field] as string) .. "x"
    end }
  end
  local spec_changes: {string:Change<declared_key.Spec>} = {
    id = append("id"), module_key = append("module_key"), runtime = append("runtime"),
    compiler = append("compiler"), host = append("host"),
    epoch = { change = function(s: declared_key.Spec) s.epoch = s.epoch + 1 end },
    timeout_ms = { change = function(s: declared_key.Spec) s.timeout_ms = s.timeout_ms + 1000 end },
    launcher = append("launcher"), declaration = append("declaration"),
    -- Keyed only for a module given the system's paths.
    system = append("system"),
    -- Keyed only for a test that runs the tool.
    program = append("program"),
    -- Keyed only where the module does not declare `store`.
    closure_store = { from = function(s: declared_key.Spec) s.effective.store = false end,
      change = function(s: declared_key.Spec) s.closure_store = "another" end },
    -- Either it or the module's `tool` keys the tool.
    runs_tool = { from = function(s: declared_key.Spec) s.effective.tool = false end,
      change = function(s: declared_key.Spec) s.runs_tool = false end },
    environment = { change = function(s: declared_key.Spec) s.environment.DECLARED = "e" end },
    -- Each of its own fields is held below.
    effective = { change = function(s: declared_key.Spec) s.effective.files["suite/data/a.txt"] = true end },
  }
  each_field_moves("Spec", fields_of("build.declared_key", "Spec"),
    function(): declared_key.Spec return full_spec(hostdir) end,
    function(s: declared_key.Spec): any return s end, key, spec_changes, {
      group = "names the tests whose specs are the same but for `id`, which `compute` " ..
        "digests the rest of once for: no input",
    })
  local effective_changes: {string:Change<declared_key.Spec>} = {
    files = { change = function(s: declared_key.Spec) s.effective.files["suite/data/a.txt"] = true end },
    reads = { change = function(s: declared_key.Spec)
      table.insert(s.effective.reads, "suite/unrelated.txt")
    end },
    host = { change = function(s: declared_key.Spec)
      table.insert(s.effective.host, hostdir .. "/elsewhere")
    end },
    tool = { from = function(s: declared_key.Spec) s.runs_tool = false end,
      change = function(s: declared_key.Spec) s.effective.tool = false end },
    store = { change = function(s: declared_key.Spec) s.effective.store = false end },
    system = { change = function(s: declared_key.Spec) s.effective.system = false end },
    named = { change = function(s: declared_key.Spec) s.effective.named = {} end },
    spelled = { change = function(s: declared_key.Spec)
      s.effective.spelled[hostdir .. "/host.txt"] = "$G/host.txt"
    end },
    located = { change = function(s: declared_key.Spec) s.effective.located.H = tmp end },
  }
  local declaration = "what the module declares, which `declaration` keys as " ..
    "`test_inputs.canonical` spells it"
  each_field_moves("Effective", fields_of("build.test_inputs", "Effective"),
    function(): declared_key.Spec return full_spec(hostdir) end,
    function(s: declared_key.Spec): any return s.effective end, key, effective_changes, {
      env = declaration .. ", and `environment` by what the worker is given",
      network = declaration .. ": a test that reaches beyond loopback has no key " ..
        "(`declared_key.keyable`)",
      processes = declaration, variables = declaration,
      caches = "content-addressed, which never changes a result (build.caches)",
      cache_paths = "where the host keeps its caches: content-addressed, which never " ..
        "changes a result (build.caches)",
      unresolved = "a module with a host path that cannot be given runs no test to key " ..
        "(`build.test`'s `unresolved`)",
    })
end

--- Every field of where the host's identity looks (`HostSources`)
--- moves what a key holds of the host, `host_identity` and
--- `system_identity`: the fields are the record's own, as the catalog
--- lists them.
local function test_every_field_of_the_host_sources_moves_the_host(tmp: string)
  local function write(name: string, text: string): string
    assert(Fs.write(tmp .. "/" .. name, text))
    return tmp .. "/" .. name
  end
  write("packages2", "p2")
  write("os2", "o2")
  write("status2", "Name: x\nCapEff: 1\nUid: 1 1 1 1\n")
  write("cpuinfo2", "flags : aes\n")
  local function make(): declared_key.HostSources
    return {
      packages = { write("packages", "p1") },
      system = { write("os", "o1"), write("release", "r1"), write("version", "v1") },
      sysname = "Linux", system_id = "s1",
      cpuinfo = write("cpuinfo", "flags : aes pclmulqdq asimd\n"), machine = "x86_64",
      status = write("status", "Name: x\nCapEff: 0\nUid: 1 1 1 1\n"),
      own_proc = true, host_id = "h1", uid = 1,
    }
  end
  local function key(sources: declared_key.HostSources): string
    local digests = declared_key.digests(tmp)
    return declared_key.host_identity(digests, sources) .. " " ..
      declared_key.system_identity(digests, sources)
  end
  local function set(field: string, value: any): Change<declared_key.HostSources>
    return { change = function(s: declared_key.HostSources)
      (s as {string:any})[field] = value
    end }
  end
  local changes: {string:Change<declared_key.HostSources>} = {
    packages = set("packages", { tmp .. "/packages2" }),
    system = { change = function(s: declared_key.HostSources) s.system[1] = tmp .. "/os2" end },
    -- Read only where `system` names none, to choose where to look.
    sysname = { from = function(s: declared_key.HostSources) s.system = nil end,
      change = function(s: declared_key.HostSources) s.sysname = "Darwin" end },
    system_id = set("system_id", "s2"), cpuinfo = set("cpuinfo", tmp .. "/cpuinfo2"),
    machine = set("machine", "aarch64"), status = set("status", tmp .. "/status2"),
    own_proc = set("own_proc", false), host_id = set("host_id", "h2"), uid = set("uid", 2),
  }
  each_field_moves("HostSources", fields_of("build.declared_key", "HostSources"), make,
    function(s: declared_key.HostSources): any return s end, key, changes, {})
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

--- A `host` path a variable names is keyed by what it holds and by the
--- name it is declared by, not by where the variable says it is: the
--- same contents at another place key the same, and the variable's
--- value in the worker's environment is held by that name too; a
--- change to what it holds moves the key, a file beneath a directory
--- as a file; and a link beneath it that leads out of it has no key.
local function test_a_host_path_a_variable_names_is_keyed_by_what_it_holds(tmp: string)
  local root = tmp .. "/root"
  tree(root)
  local base = assert(Fs.absolute(tmp))
  local function product(where: string, contents: string): string
    local dir = base .. "/" .. where
    assert(Fs.mkdirs(dir .. "/o/bin"))
    assert(Fs.write(dir .. "/o/bin/cosmic", contents))
    return dir
  end
  local function key_at(where: string, declared: string): string
    local s = spec({ DECLARED = "d", TMPDIR = "/tmp", PRODUCT = where })
    s.effective.host = { declared }
    s.effective.env.PRODUCT = true
    s.effective.named = { PRODUCT = true }
    s.effective.variables = { "DECLARED", "PRODUCT" }
    s.declaration = s.declaration .. "\nhost " .. string.format("%q", declared)
    test_inputs.resolve(s.effective, s.environment, { root })
    assert(s.effective.unresolved == "", s.effective.unresolved)
    return key_of(root, s)
  end
  local one, two = product("one", "cosmic\n"), product("two", "cosmic\n")
  local file = "$PRODUCT/o/bin/cosmic"
  assert(key_at(one, file) == key_at(two, file), "the same contents elsewhere")
  assert(key_at(one, "$PRODUCT") == key_at(two, "$PRODUCT"), "the same directory elsewhere")
  assert(key_at(one, file) ~= key_at(one, "$PRODUCT"), "another declaration")
  assert(Fs.write(two .. "/o/bin/cosmic", "another cosmic\n"))
  assert(key_at(one, file) ~= key_at(two, file), "another file's contents")
  assert(key_at(one, "$PRODUCT") ~= key_at(two, "$PRODUCT"), "another directory's contents")
  local before = key_at(one, "$PRODUCT")
  assert(Fs.write(one .. "/o/new", ""))
  assert(key_at(one, "$PRODUCT") ~= before, "a file added beneath it")
  -- Two variables' places swapped, what each holds the same: the same key.
  local function key_of_two(a: string, b: string): string
    local s = spec({ DECLARED = "d", TMPDIR = "/tmp", A = a, B = b })
    s.effective.host = { "$A/o/bin/cosmic", "$B/o/bin/cosmic" }
    s.effective.named = { A = true, B = true }
    s.effective.variables = { "A", "B" }
    test_inputs.resolve(s.effective, s.environment, { root })
    return key_of(root, s)
  end
  local early, late = product("early", "a\n"), product("zlate", "b\n")
  local swapped_early, swapped_late = product("early2", "b\n"), product("zlate2", "a\n")
  assert(key_of_two(early, late) == key_of_two(swapped_late, swapped_early),
    "the variables' places in another order")
  assert(key_of_two(early, late) ~= key_of_two(swapped_early, swapped_late),
    "what each holds, swapped")
  -- A link within it is held by where it leads; one out of it has no key.
  assert(Fs.symlink("bin/cosmic", one .. "/o/within"))
  assert(key_at(one, "$PRODUCT") ~= nil)
  assert(Fs.symlink("../../two/o/bin/cosmic", one .. "/o/out"))
  local s = spec({ DECLARED = "d", TMPDIR = "/tmp", PRODUCT = one })
  s.effective.host = { "$PRODUCT" }
  s.effective.named = { PRODUCT = true }
  s.effective.variables = { "PRODUCT" }
  test_inputs.resolve(s.effective, s.environment, { root })
  local key, why = declared_key.compute(declared_key.digests(root), s)
  assert(key == nil and why:find("leads out of " .. one, 1, true), why)
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

--- A digest of named modules (`declared_key.harness`: the harness's,
--- over each module's source, and the closure store's salt, over its
--- source and bytecode) holds each module it names by what `sources`
--- says it is, and nothing else: a change to either word moves it, and
--- a module it does not name does not, whatever requires it.
local function test_a_named_module_moves_the_digest()
  local sources: {string:string} = {
    ["build.test_worker"] = "w wb", ["build.test_sandbox"] = "s sb", ["build.caches"] = "c cb",
    ["cosmic.fs"] = "f fb", ["build.docs"] = "d db",
  }
  local names = { "build.test_worker", "build.test_sandbox", "build.caches", "cosmic.fs" }
  local before = declared_key.harness(names, sources)
  sources["build.docs"] = "d2 db2"
  assert(declared_key.harness(names, sources) == before, "a module it does not name")
  for _, name in ipairs(names) do
    local was = sources[name]
    local source, bytecode = was:match("^(%S+) (%S+)$")
    sources[name] = source .. "2 " .. bytecode
    assert(declared_key.harness(names, sources) ~= before, name .. "'s source")
    sources[name] = source .. " " .. bytecode .. "2"
    assert(declared_key.harness(names, sources) ~= before, name .. "'s bytecode")
    sources[name] = was
  end
  -- Its order is no part of it.
  assert(declared_key.harness({ "cosmic.fs", "build.caches", "build.test_sandbox",
    "build.test_worker" }, sources) == before)
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

--- On macOS, which has no /proc, no /etc/os-release and no package
--- database, the system volume's SystemVersion.plist names both the
--- kernel and the system (`declared_key.system_sources`): an update of
--- it moves the host's identity and what it has installed alike. What
--- the host names of what it has installed beyond that volume
--- (COSMIC_SYSTEM_ID: Xcode, Homebrew) moves only what it has
--- installed, which only a module given the system's paths is keyed by.
local function test_a_macos_host_is_keyed_by_its_system_version(tmp: string)
  local darwin = declared_key.system_sources("Darwin")
  local plist = "/System/Library/CoreServices/SystemVersion.plist"
  assert(darwin[1] == plist and darwin[2] == plist and darwin[3] == "", table.concat(darwin, " "))
  assert(declared_key.system_sources("Linux")[2] == "/proc/sys/kernel/osrelease")
  local fake = tmp .. "/SystemVersion.plist"
  local system: {string} = {}
  for i, path in ipairs(darwin) do system[i] = path == plist and fake or path end
  local sources: declared_key.HostSources = {
    packages = { tmp .. "/no-packages" }, system = system, status = tmp .. "/no-status",
    cpuinfo = tmp .. "/no-cpuinfo", machine = "arm64", own_proc = false,
    host_id = "macos-15", system_id = "macos15 20250901.1", uid = 501,
  }
  local function both(): string, string
    return declared_key.host_identity(declared_key.digests(tmp), sources),
      declared_key.system_identity(declared_key.digests(tmp), sources)
  end
  assert(Fs.write(fake, "<key>ProductBuildVersion</key><string>24G84</string>\n"))
  local host, installed = both()
  assert(Fs.write(fake, "<key>ProductBuildVersion</key><string>24G90</string>\n"))
  local updated_host, updated = both()
  assert(updated_host ~= host, "an update of the system moved no host")
  assert(updated ~= installed, "an update of the system moved nothing installed")
  sources.system_id = "macos15 20250908.1"
  local same_host, other = both()
  assert(same_host == updated_host, "what is installed beyond the system moved the host")
  assert(other ~= updated, "what is installed beyond the system moved nothing installed")
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
  local file = { tmp .. "/host/file" }
  assert(key_on(one, false, file) == key_on(other, false, file), "a module given a file of the host's")
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
--- moves -- `boot_hash`, over every file of the tool's trees but their
--- tests, and `projected`, over the whole projection -- so a tool
--- written again for an edit that moved nothing it carries (a boot
--- after a comment in a test) keys as it did, in the program that runs
--- and in o/bin alike, while a carried module and the core move both.
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

--- A core that carries DWARF, as the checked core does, is keyed by its
--- image wherever a key holds it -- the launcher an artifact runs, the
--- program a test runs, the core that program extracts -- so a rebuild
--- whose DWARF names another checkout's directory, as musl's does,
--- moves none of them, and one whose code moved moves each.
local function test_a_core_carrying_dwarf_is_keyed_by_its_image(tmp: string)
  tree(tmp)
  local root = assert(Fs.absolute(tmp))
  local path = root .. "/cosmic-checked"
  local core_path = root .. "/core-checked"
  local meta: {string:string} = { writer = "w", compiler = "c" }
  local function identities(core: string): {string}
    program_at(path, core, meta, "bytecode")
    assert(Fs.write(core_path, core))
    local digests = declared_key.digests(root)
    return { declared_key.launcher_identity(digests, path),
      declared_key.program_identity(digests, { path }),
      declared_key.program_identity(digests, { core_path }) }
  end
  local one = identities(fixture.elf("code", "DW_AT_comp_dir /home/runner/work/cosmic"))
  local other = identities(fixture.elf("code", "DW_AT_comp_dir /__w/elsewhere/cosmic/cosmic"))
  local moved = identities(fixture.elf("edoc", "DW_AT_comp_dir /home/runner/work/cosmic"))
  for i, what in ipairs({ "launcher", "program", "extracted core" }) do
    assert(one[i] == other[i], "the DWARF moved the " .. what)
    assert(one[i] ~= moved[i], "the code left the " .. what)
  end
end

--- The running core's runtime identity is remembered by the digest of
--- its bytes: a run on a core an earlier one keyed by its image keys it
--- so again without reading it, one keyed whole keys as the binary
--- names it, and one the running core is not keys as named too.
local function test_the_runtime_identity_is_remembered_by_the_core(tmp: string)
  local digests = declared_key.digests(tmp)
  local image = ("ab"):rep(32)
  local core = ("cd"):rep(32)
  digests.hashed["runtime-image\0" .. core] = "image 1 2\0" .. image
  assert(declared_key.runtime_identity(digests, "raw", core, "basis") ==
    core_image.runtime(image, 1, 2, "basis"))
  assert(digests.used["runtime-image\0" .. core])
  digests.hashed["runtime-image\0" .. core] = "whole\0" .. core
  assert(declared_key.runtime_identity(digests, "raw", core, "basis") == "raw")
  -- Not the running core, whose bytes this cannot read: as named.
  assert(declared_key.runtime_identity(digests, "raw", ("ef"):rep(32), "basis") == "raw")
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

--- `key_part` hex-encodes both the path and the answer; these literals
--- pin the encoding for the bytes most likely to break a lookup-table
--- rewrite of it: NUL, newline, DEL, and 0xff, plus a multibyte UTF-8
--- path, none of which are ASCII letters or digits.
local function test_key_part_matches_known_hex_for_edge_bytes()
  local edges = string.char(0x00, 0x0a, 0x7f, 0xff)
  assert(declared_key.key_part("s", edges, "") == "s 000a7fff ")
  assert(declared_key.key_part("o", "", edges) == "o  000a7fff")
  assert(declared_key.key_part("d", "caf\xc3\xa9", "x") == "d 636166c3a9 78")
end
