--- core/main.c's `--database` start: a bare core run against a database
--- file of its own, `core --database <path> [program args]`, with no
--- artifact, manifest or launcher. The tests build their databases with
--- the tree's own schema, from the modules the test itself loads, and
--- start the core past its launcher, as core/startup_test.tl does.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local database_start_fixture = require("build.database_start_fixture")

--- The core is started past its launcher, and `/proc` is what a probe
--- reads of its own descriptors.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/proc", letters = "r" } },
}

local write_database = database_start_fixture.write_database
local core_digest = database_start_fixture.core_digest
local core_path = database_start_fixture.core_path
local environment = database_start_fixture.environment
local run = database_start_fixture.run
local fields = database_start_fixture.fields
local info_module = database_start_fixture.info_module
local info_database = database_start_fixture.info_database

--- With no option, a bare core is what it has been: no database, no tree
--- to boot from.
local function test_a_bare_core_without_the_option_has_no_program()
  local core = core_path()
  if core == nil then return end
  local r = run({ core })
  assert(r.code == 2, "exit " .. tostring(r.code))
  assert((assert(r.stderr)):find("cosmic: no database attached, and no tree to boot from", 1, true),
    tostring(r.stderr))
end

--- The first argument is what the option is: `--database` anywhere later
--- is the program's own.
local function test_the_option_is_taken_only_as_the_first_argument()
  local core = core_path()
  if core == nil then return end
  local r = run({ core, "--other", "--database", "x" })
  assert(r.code == 2, "exit " .. tostring(r.code))
  assert((assert(r.stderr)):find("no database attached", 1, true), tostring(r.stderr))
end

--- The program the database names runs, handed what follows the path as
--- its arguments and the path itself as its own name, and holds exactly
--- one database: its own.
local function test_the_database_runs_as_the_program(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = info_database(tmp)
  local r = run({ core, "--database", path, "a", "b c" })
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local out = fields(assert(r.stdout))
  assert(out.arg0 == path, tostring(out.arg0))
  assert(out.args == "a|b c", tostring(out.args))
  assert(out.databases == "1", tostring(out.databases))
  assert(out.main == "probe.main", tostring(out.main))
end

--- The runtime's identity is the database's meta and the core's own
--- digest: the core's, as the database recorded it, and a runtime made
--- of it and the database's basis. The program's file is the core, and
--- its artifact is the database.
local function test_the_runtime_identity_is_the_database_and_the_core(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = info_database(tmp)
  local r = run({ core, "--database", path })
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local out = fields(assert(r.stdout))
  assert(out.context == "database-v1", tostring(out.context))
  assert(out.host_image == core_digest(), tostring(out.host_image))
  assert(out.runtime == "true", tostring(out.runtime))
  assert(out.artifact == assert(sys.realpath(path)), tostring(out.artifact))
  assert(out.executable == core, tostring(out.executable))
end

--- A module the database lacks is not found: nothing of the tree, the
--- launcher or an artifact stands behind it. What it holds loads, and its
--- own `imports` rows are what [`Store.requires`] answers.
local PROBE_MODULES <const> = [==[
local Store = require("cosmic.store")
local function say(name, value) print(name .. "\t" .. tostring(value)) end
return function(args)
  say("json", (pcall(require, "cosmic.json")))
  say("value", require("extra.value"))
  say("requires", table.concat(Store.requires("extra.value"), ","))
  say("databases", #Store.databases())
  local attached, why = Store.attach(args[1])
  say("attached", attached)
  say("databases_after", #Store.databases())
  say("requires_after", table.concat(Store.requires("extra.value"), ","))
  say("shadow", require("extra.shadow"))
  say("second", require("extra.second"))
  say("main_after", Store.meta("main"))
  return 0
end
]==]

local function test_require_and_the_store_see_only_that_database(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = tmp .. "/program.db"
  write_database(path, {
    { name = "probe.main", kind = "main", source = PROBE_MODULES, requires = { "cosmic.store" } },
    { name = "extra.value", kind = "module", source = 'return "from-database:" .. require("extra.base")',
      requires = { "extra.base" } },
    { name = "extra.base", kind = "module", source = 'return "base"', requires = {} },
    { name = "extra.shadow", kind = "module", source = 'return "own"', requires = {} },
  }, { main = "probe.main", core = core_digest(), library = true })
  local attached = tmp .. "/attached.db"
  write_database(attached, {
    { name = "extra.shadow", kind = "module", source = 'return "attached"', requires = {} },
    { name = "extra.second", kind = "module", source = 'return "second"', requires = {} },
  }, { library = false })
  local r = run({ core, "--database", path, attached })
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local out = fields(assert(r.stdout))
  assert(out.json == "false", "the tree's cosmic.json was found: " .. tostring(out.json))
  assert(out.value == "from-database:base", tostring(out.value))
  assert(out.requires == "extra.base", tostring(out.requires))
  assert(out.databases == "1", tostring(out.databases))
  -- Attaching still searches the new database first, ahead of its own.
  assert(out.attached == "true", tostring(out.attached))
  assert(out.databases_after == "2", tostring(out.databases_after))
  assert(out.shadow == "attached", tostring(out.shadow))
  assert(out.second == "second", tostring(out.second))
  -- What reads the binary's own rows still reads the database's, not the attached one's.
  assert(out.requires_after == "extra.base", tostring(out.requires_after))
  assert(out.main_after == "probe.main", tostring(out.main_after))
end

--- Started again, the process is on the same database, with nothing to
--- hand on, and so is a child it starts that way.
local function test_a_relaunch_and_its_child_stay_on_the_database(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = info_database(tmp)
  local r = run({ core, "--database", path, "spawn" })
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local out = fields(assert(r.stdout))
  local real = assert(sys.realpath(path))
  assert(out.relaunch == core .. "|--database|" .. real, tostring(out.relaunch))
  assert(out.relaunch_env == "true" and out.relaunch_fds == "true")
  assert(out.child_code == "0", tostring(out.child_code) .. ": " .. tostring(out.child_stderr))
  assert(out.child_databases == "1", tostring(out.child_databases))
  assert(out.child_main == "probe.main", tostring(out.child_main))
  assert(out.child_args == "child|x y", tostring(out.child_args))
end

--- A core run from a cache entry -- a name that holds its target, its
--- configuration, its length and its digest -- is hashed once: the stamp
--- the first start leaves beside it (core/startup.c's `stamp_write`) says
--- it was, and a start that finds the stamp holding does not hash it
--- again. A write to the entry in place, which keeps its inode and size
--- and moves its times, makes the stamp stale, so the next start hashes it
--- and finds the database was not written for these bytes.
local function test_a_core_a_stamp_vouches_for_is_not_hashed_again_until_it_is_written(tmp: string)
  local core = core_path()
  -- TODO: say why this runs on Linux alone, or run it elsewhere: the guard
  -- came with no reason, and a copy of the core with a byte flipped may
  -- break a macOS core's code signature.
  if core == nil or assert(sys.uname()).sysname ~= "Linux" then return end
  local prefix = Fs.basename(core):match("^(core%-%d+%-%d+%-)%d+%-%x+$")
  if prefix == nil then return end
  local bytes = assert(Fs.read(core))
  local digest = core_digest()
  local directory = tmp .. "/cores"
  assert(Fs.mkdirs(directory))
  local copy = directory .. "/" .. prefix .. #bytes .. "-" .. digest
  assert(Fs.write(copy, bytes))
  assert(Fs.chmod(copy, tonumber("755", 8)))
  local path = info_database(tmp)
  local stamp = directory .. "/.verified-" .. Fs.basename(copy)
  -- A stamp is written only once a second has passed since the entry changed.
  local _, _ = Clock.sleep_ns(Clock.ms(1100))
  assert(not Fs.exists(stamp), "a stamp before any start")
  local first = run({ copy, "--database", path })
  assert(first.ok, "exit " .. tostring(first.code) .. ": " .. tostring(first.stderr))
  assert(Fs.exists(stamp), "the first start left no stamp")
  local second = run({ copy, "--database", path })
  assert(second.ok, "exit " .. tostring(second.code) .. ": " .. tostring(second.stderr))
  -- Written in place, a second or more after the stamp: the same inode and
  -- size, other times. The last byte is no part of what the core runs.
  local _, _ = Clock.sleep_ns(Clock.ms(1100))
  local fd = assert(sys.open(copy, sys.O_RDWR))
  local last = assert(sys.lseek(fd, -1, sys.SEEK_END))
  local old = assert(sys.read(fd, 1))
  assert(sys.lseek(fd, last, sys.SEEK_SET))
  assert(sys.write(fd, string.char(old:byte() ~ 1)))
  assert(sys.close(fd))
  local third = run({ copy, "--database", path })
  assert(third.code == 2 and (assert(third.stderr)):find("another core", 1, true),
    "exit " .. tostring(third.code) .. ": " .. tostring(third.stderr))
end

--- A relative path is named absolutely (and with its links followed), so
--- a child started elsewhere reaches the same file.
local function test_a_relaunch_names_the_database_absolutely(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = info_database(tmp)
  local env = environment()
  local r = assert(Child.run({ core, "--database", "program.db" }, { env = env, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local out = fields(assert(r.stdout))
  local real = assert(sys.realpath(path))
  assert(out.relaunch == core .. "|--database|" .. real, tostring(out.relaunch))
  assert(out.artifact == real, tostring(out.artifact))
end

--- What a start that says nothing of a launcher is told of none: the
--- program runs with nothing of the private contract in its environment
--- and none of the portable artifact's descriptors, so nothing of the
--- launcher or the artifact is opened, and the retained descriptor it
--- does hold -- its core -- is refused its own program like the
--- artifact's is.
local DESCRIPTORS <const> = [==[
local sys = require("cosmic.sys")
local Fs = require("cosmic.fs")
local function say(name, value) print(name .. "\t" .. tostring(value)) end
return function(args)
  local executable = assert(sys.readlink("/proc/self/exe"))
  local held = 0
  local core_fd
  for _, name in ipairs(assert(Fs.list("/proc/self/fd"))) do
    local target = sys.readlink("/proc/self/fd/" .. name)
    if target == args[1] then say("opened_artifact", name) end
    if target == executable then core_fd = tonumber(name) end
    held = held + 1
  end
  say("core_fd", core_fd ~= nil)
  local ok, why = pcall(sys.dup, core_fd)
  say("dup_core", ok)
  say("dup_why", why)
  say("portable_env", sys.getenv("COSMIC_PORTABLE_ARTIFACT_FD") or sys.getenv("COSMIC_PORTABLE_CORE_FD"))
  return 0
end
]==]

local function test_no_artifact_or_launcher_is_opened_and_the_core_is_held_back(tmp: string)
  local core = core_path()
  -- The probe reads the descriptors it holds through /proc, which only
  -- Linux has.
  if core == nil or not Fs.is_dir("/proc/self/fd") then return end
  local path = tmp .. "/program.db"
  write_database(path, {
    { name = "probe.main", kind = "main", source = DESCRIPTORS, requires = { "cosmic.sys", "cosmic.fs" } },
  }, { main = "probe.main", core = core_digest(), library = true })
  local env = environment()
  assert(env.COSMIC_PORTABLE_ARTIFACT_FD == nil and env.COSMIC_PORTABLE_CORE_FD == nil)
  local program = assert(Proc.executable())
  local r = run({ core, "--database", path, program })
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local out = fields(assert(r.stdout))
  assert(out.opened_artifact == nil, "the artifact was open as descriptor " .. tostring(out.opened_artifact))
  assert(out.portable_env == "nil", tostring(out.portable_env))
  assert(out.core_fd == "true", "the retained core descriptor was not found")
  assert(out.dup_core == "false", "the core's descriptor was duplicated")
  assert((out.dup_why or ""):find("retained artifact descriptor", 1, true), tostring(out.dup_why))
end

--- The database is named in what a refusal says, whatever its reason,
--- and nothing runs.
local function refused(core: string, path: string, reason: string, argv?: {string})
  local command: {string} = { core, "--database", path }
  for _, word in ipairs(argv or {}) do command[#command + 1] = word end
  local r = run(command)
  assert(r.code == 2, reason .. ": exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  assert(r.stdout == "", reason .. ": printed " .. tostring(r.stdout))
  local stderr = assert(r.stderr)
  assert(stderr:find("cosmic: --database " .. path .. ": ", 1, true), reason .. ": " .. stderr)
  assert(stderr:find(reason, 1, true), reason .. ": " .. stderr)
end

local function test_a_missing_database_is_refused(tmp: string)
  local core = core_path()
  if core == nil then return end
  refused(core, tmp .. "/absent.db", "No such file or directory")
end

local function test_an_unreadable_database_is_refused(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = info_database(tmp, "locked.db")
  assert(sys.chmod(path, 0))
  -- A process that may read it whatever its mode finds a good database.
  if sys.access(path, sys.R_OK) then return end
  refused(core, path, "Permission denied")
end

local function test_a_directory_is_refused(tmp: string)
  local core = core_path()
  if core == nil then return end
  refused(core, tmp, "it is not a regular file")
end

--- A FIFO has no content to read and opening one for reading waits for a
--- writer: it is refused like any file that is not regular, not waited on.
local function test_a_fifo_is_refused(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = tmp .. "/fifo"
  assert(sys.mkfifo(path, 0x1a4))
  refused(core, path, "it is not a regular file")
end

--- A path that is a link opens the file it names, which the relaunch and
--- the artifact then name without the link.
local function test_a_symlinked_database_path_opens_its_target(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = info_database(tmp)
  assert(Fs.symlink(path, tmp .. "/link.db"))
  local r = run({ core, "--database", tmp .. "/link.db" })
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local out = fields(assert(r.stdout))
  assert(out.artifact == assert(sys.realpath(path)), tostring(out.artifact))
end

local function test_a_file_that_is_not_sqlite_is_refused(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = tmp .. "/text.db"
  assert(Fs.write(path, string.rep("this is not a database\n", 200)))
  refused(core, path, "not a cosmic database: file is not a database")
end

local function test_an_empty_file_is_refused(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = tmp .. "/empty.db"
  assert(Fs.write(path, ""))
  refused(core, path, "not a cosmic database")
end

local function test_a_database_with_no_main_is_refused(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = tmp .. "/nomain.db"
  write_database(path, { info_module() }, { core = core_digest(), library = true })
  refused(core, path, "it has no main meta row")
end

local function test_a_database_for_another_core_is_refused(tmp: string)
  local core = core_path()
  if core == nil then return end
  local other = tmp .. "/other.db"
  write_database(other, { info_module() },
    { main = "probe.main", core = string.rep("0", 64), library = true })
  refused(core, other, "it was written for another core than this one")
  local unrecorded = tmp .. "/unrecorded.db"
  write_database(unrecorded, { info_module() }, { main = "probe.main", library = true })
  refused(core, unrecorded, "it records no core_sha256")
  local garbled = tmp .. "/garbled.db"
  write_database(garbled, { info_module() }, { main = "probe.main", core = "not hex", library = true })
  refused(core, garbled, "not a sha256 in hex")
end

local function test_the_option_without_a_path_is_refused()
  local core = core_path()
  if core == nil then return end
  local r = run({ core, "--database" })
  assert(r.code == 2, "exit " .. tostring(r.code))
  assert((assert(r.stderr)):find("cosmic: --database names no database", 1, true), tostring(r.stderr))
end

--- A path with the characters a URI reads as syntax opens as itself:
--- nothing in it picks another VFS or turns a mode off.
local function test_a_path_with_uri_syntax_opens_as_itself(tmp: string)
  local core = core_path()
  if core == nil then return end
  assert(Fs.mkdirs(tmp .. "/odd?vfs=cosmic&mode=rw#%41"))
  local path = info_database(tmp .. "/odd?vfs=cosmic&mode=rw#%41", "a b.db")
  local r = run({ core, "--database", path })
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  assert(fields(assert(r.stdout)).main == "probe.main")
end
