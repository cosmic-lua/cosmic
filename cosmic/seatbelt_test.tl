local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")
local Seatbelt = require("cosmic.seatbelt")

local BASE <const> = [[(version 1)
(deny default)
(allow file-read-metadata)
(allow file-read-data (literal (param "ROOT")))
(allow sysctl-read)
(allow signal (target self))
(allow process-info-pidinfo (target self))
]]

local function compile(policy: Sandbox.Policy, paths?: {string:Seatbelt.Path}): Seatbelt.Profile
  return (assert(Seatbelt.compile(policy, { paths = paths or {} })))
end

local function test_empty_policy_denies_every_file_network_and_process_fork()
  local out = compile({})
  assert(out.text == BASE, out.text)
  local held = 0
  for _, _ in pairs(out.parameters) do held = held + 1 end
  assert(out.parameters.ROOT == "/" and held == 1)
  assert(out.rlimits.nofile == 1024 and out.rlimits.core == 0)
  assert((assert(Seatbelt.compile({}))).text == BASE)
end

local function test_letters_grant_only_their_operations()
  local operations: {string:string} = {
    r = "file-read*", w = "file-write-data", x = "process-exec file-map-executable",
    c = "file-write-create file-write-unlink", u = "network-outbound",
  }
  for letter, operation in pairs(operations) do
    local out = compile({ grants = { { path = "one", letters = letter } } },
      { one = { path = "/one", directory = false } })
    assert(out.text == BASE .. '(allow ' .. operation .. ' (literal (param "PATH_1")))\n', out.text)
    assert(out.parameters.PATH_1 == "/one" and out.parameters.PATH_2 == nil)
  end
end

local function test_directory_profile_is_recursive_and_parameterized()
  local out = compile({ grants = { { path = "data", letters = "rwc" } } },
    { data = { path = "/private/data", directory = true } })
  assert(out.text == BASE .. [[(allow file-read* (subpath (param "PATH_1")))
(allow file-write-data (subpath (param "PATH_1")))
(allow file-write-create file-write-unlink (subpath (param "PATH_1")))
]], out.text)
  assert(out.parameters.PATH_1 == "/private/data")
  assert(not out.text:find("/private/data", 1, true), out.text)
end

local function test_promises_are_precise_and_fattr_only_reaches_writable_grants()
  local out = compile({ promises = { "jit", "fork", "fattr" }, grants = {
    { path = "read", letters = "r" }, { path = "write", letters = "w" },
  } }, { read = { path = "/read", directory = false }, write = { path = "/write", directory = false } })
  assert(out.text == BASE .. [[(allow process-fork)
(allow dynamic-code-generation)
(allow file-read* (literal (param "PATH_1")))
(allow file-write-data (literal (param "PATH_2")))
(allow file-write-mode file-write-owner file-write-times file-write-flags file-write-xattr (literal (param "PATH_2")))
]], out.text)
  assert(not out.text:find("mach", 1, true) and not out.text:find("file-write*", 1, true))
  local read = compile({ promises = { "fattr" }, grants = { { path = "read", letters = "r" } } },
    { read = { path = "/read", directory = false } })
  assert(not read.text:find("file-write", 1, true))
end

local function test_quotes_parentheses_newlines_and_equals_never_enter_profile_text()
  local attacks = { '/data/")) (allow default) ;', "/data/\n(allow default)", "/data/PATH_1=x" }
  for _, path in ipairs(attacks) do
    local out = compile({ grants = { { path = path, letters = "ru" } } },
      { [path] = { path = path, directory = false } })
    assert(out.text == BASE .. [[(allow file-read* (literal (param "PATH_1")))
(allow network-outbound (literal (param "PATH_1")))
]], out.text)
    assert(out.parameters.PATH_1 == path)
    assert(not out.text:find(path, 1, true), out.text)
  end
end

local function test_aliases_and_grant_order_produce_one_canonical_profile()
  local paths: {string:Seatbelt.Path} = {
    a = { path = "/same", directory = false }, b = { path = "/same", directory = false },
    c = { path = "/other", directory = true },
  }
  local first = compile({ grants = {
    { path = "a", letters = "x" }, { path = "b", letters = "r" }, { path = "c", letters = "w" },
  } }, paths)
  local second = compile({ grants = {
    { path = "c", letters = "w" }, { path = "b", letters = "r" }, { path = "a", letters = "x" },
  } }, paths)
  assert(first.text == second.text, second.text)
  assert(first.parameters.PATH_1 == "/other" and first.parameters.PATH_2 == "/same")
  assert(first.parameters.PATH_3 == nil)
  assert(first.text == BASE .. [[(allow file-write-data (subpath (param "PATH_1")))
(allow file-read* (literal (param "PATH_2")))
(allow process-exec file-map-executable (literal (param "PATH_2")))
]], first.text)
end

local function test_system_expands_mac_paths_only_and_cosmic_names_the_supplied_program()
  local paths: {string:Seatbelt.Path} = {
    ["/System/Library"] = { path = "/System/Library", directory = true },
    ["/System/Cryptexes/OS"] = { path = "/System/Cryptexes/OS", directory = true },
    ["/etc/passwd"] = { path = "/private/etc/passwd", directory = false },
    ["/dev/null"] = { path = "/dev/null", directory = false },
    ["/lib"] = { path = "/lib", directory = true },
    ["program"] = { path = "/opt/cosmic", directory = false },
  }
  local out = assert(Seatbelt.compile({ profiles = { "system", "cosmic" } },
    { paths = paths, executable = "program" }))
  assert(out.parameters.PATH_1 == "/System/Cryptexes/OS")
  assert(out.parameters.PATH_2 == "/System/Library")
  assert(out.parameters.PATH_3 == "/dev/null")
  assert(out.parameters.PATH_4 == "/opt/cosmic")
  assert(out.parameters.PATH_5 == "/private/etc/passwd" and out.parameters.PATH_6 == nil)
  assert(out.text == BASE .. [[(allow file-read* (subpath (param "PATH_1")))
(allow process-exec file-map-executable (subpath (param "PATH_1")))
(allow file-read* (subpath (param "PATH_2")))
(allow process-exec file-map-executable (subpath (param "PATH_2")))
(allow file-read* (literal (param "PATH_3")))
(allow file-write-data (literal (param "PATH_3")))
(allow file-read* (literal (param "PATH_4")))
(allow process-exec file-map-executable (literal (param "PATH_4")))
(allow file-read* (literal (param "PATH_5")))
]], out.text)
end

local function test_rlimits_are_returned_for_the_enforcement_caller()
  local out = compile({ limits = { open_files = 9, file_bytes = 100, cpu_seconds = 2 } })
  assert(out.rlimits.nofile == 9 and out.rlimits.core == 0)
  assert(out.rlimits.fsize == 100 and out.rlimits.cpu == 2)
  assert(out.text == BASE)
end

local function test_unmet_policy_fields_are_refused()
  local cases: {{any}} = {
    { { isolate = { "file" } }, "isolate" },
    { { connect = { "example.com:443" } }, "connect" },
    { { loopback = { "127.0.0.1" } }, "loopback" },
    { { promises = { "nest" } }, "nest" },
    { { grants = { { path = "a", from = "b", letters = "r" } } }, "from" },
    { { limits = { processes = 2 } }, "limits.processes" },
    { { database = "/does/not/exist" }, "database" },
    { { set_env_digests = { A = string.rep("0", 64) } }, "set_env_digests" },
    { { profiles = { "unrecognized" } }, "profiles" },
    { { grants = { { path = "a", letters = "bad" } } }, "letters" },
    { { profiles = { "cosmic" } }, "executable" },
    { { set_env = { A = "secret" }, set_env_digests = { A = string.rep("0", 64) } }, "set_env_digests" },
  }
  for _, case in ipairs(cases) do
    local out, why = Seatbelt.compile(case[1] as Sandbox.Policy, { paths = {} })
    assert(out == nil and why:find(case[2] as string, 1, true), why)
  end
end

--- macOS runs no relay for `connect`, which a Linux start does: it is refused
--- naming the relay, on every host that compiles a profile.
local function test_connect_is_refused_naming_the_relay_macos_does_not_run()
  local out, why = Seatbelt.compile({ connect = { "example.com:443" } }, { paths = {} })
  assert(out == nil and why:find("connect needs the network relay", 1, true), tostring(why))
  assert(why:find("macOS does not run yet", 1, true), why)
end

--- `tmp`'s directory is made after the profile, so the profile grants it
--- `rwc` through a parameter its caller sets: none is in the text or the
--- parameters until then.
local function test_tmp_is_granted_through_a_parameter_the_caller_sets()
  local out = compile({ tmp = true })
  assert(out.text == BASE .. [[(allow file-read* (subpath (param "TMP")))
(allow file-write-data (subpath (param "TMP")))
(allow file-write-create file-write-unlink (subpath (param "TMP")))
]], out.text)
  assert(out.tmp == "TMP" and out.parameters.TMP == nil)
  assert(compile({}).tmp == nil)
  local held = compile({ tmp = true, promises = { "fattr" } })
  assert(held.text:find('file-write-xattr (subpath (param "TMP"))', 1, true), held.text)
end

local function test_a_database_grants_its_core_and_itself_and_not_this_programs_file(tmp: string)
  local database = tmp .. "/sealed.db"
  assert(Fs.write(database, "a regular file"))
  local paths: {string:Seatbelt.Path} = {
    ["/core"] = { path = "/private/core", directory = false },
    [database] = { path = database, directory = false },
    ["/launcher"] = { path = "/private/launcher", directory = false },
  }
  local policy: Sandbox.Policy = { database = database, profiles = { "cosmic" } }
  local out = assert(Seatbelt.compile(policy,
    { paths = paths, core = "/core", database = database, executable = "/launcher" }))
  assert(out.text == BASE .. '(allow file-read* (literal (param "PATH_1")))\n' ..
      '(allow process-exec file-map-executable (literal (param "PATH_1")))\n' ..
      '(allow file-read* (literal (param "PATH_2")))\n', out.text)
  -- Sorted by path: the core's /private/core is before the database's path.
  assert(out.parameters.PATH_1 == "/private/core" and out.parameters.PATH_2 == database, out.text)
  assert(not out.text:find("write", 1, true) and not out.text:find("launcher", 1, true), out.text)
  for _, value in pairs(out.parameters) do
    assert(value ~= "/private/launcher", "the launcher is granted a program on a database")
  end
end

local function test_a_database_needs_the_core_and_the_file_the_core_runs_on(tmp: string)
  local database, other = tmp .. "/sealed.db", tmp .. "/other.db"
  assert(Fs.write(database, "a regular file"))
  assert(Fs.write(other, "another one"))
  local paths: {string:Seatbelt.Path} = {
    ["/core"] = { path = "/private/core", directory = false },
    [database] = { path = database, directory = false },
    [other] = { path = other, directory = false },
  }
  local policy: Sandbox.Policy = { database = database }
  local out, why = Seatbelt.compile(policy, { paths = paths })
  assert(out == nil and why:find("database needs the core", 1, true), tostring(why))
  out, why = Seatbelt.compile(policy, { paths = paths, core = "/core" })
  assert(out == nil and why:find("database needs the core", 1, true), tostring(why))
  out, why = Seatbelt.compile(policy, { paths = paths, core = "/core", database = other })
  assert(out == nil and why:find("is not the database the core is run on", 1, true), tostring(why))
  -- The same file by another name is the one.
  paths["/by-link"] = { path = database, directory = false }
  assert(Seatbelt.compile(policy, { paths = paths, core = "/core", database = "/by-link" }))
end

--- What a policy reaches on macOS is macOS's "system" list, not Linux's.
local function test_the_grants_a_policy_reaches_are_macoss_own()
  local held: {string:string} = {}
  for _, grant in ipairs(Seatbelt.grants({ profiles = { "system" },
      grants = { { path = "/srv", letters = "r" } } })) do held[grant.path] = grant.letters end
  assert(held["/System/Library"] == "rx" and held["/sbin"] == "rx" and held["/srv"] == "r")
  assert(#Seatbelt.grants({}) == 0)
end

local function test_missing_or_noncanonical_host_paths_fail_closed()
  local out, why = Seatbelt.compile({ grants = { { path = "a", letters = "r" } } }, { paths = {} })
  assert(out == nil and why:find("resolved host path", 1, true), why)
  for _, path in ipairs({ "relative", "/has/../parent", "/has/./dot", "/double//slash", "/trailing/", "/nul\0" }) do
    out, why = Seatbelt.compile({ grants = { { path = "a", letters = "r" } } },
      { paths = { a = { path = path, directory = false } } })
    assert(out == nil and why:find("canonical host path", 1, true), why)
  end
  out, why = Seatbelt.compile({ grants = { { path = "a", letters = "r" }, { path = "b", letters = "w" } } },
    { paths = { a = { path = "/same", directory = true }, b = { path = "/same", directory = false } } })
  assert(out == nil and why:find("two directory kinds", 1, true), why)
end

local function test_compiling_does_not_mutate_the_policy_or_paths()
  local policy: Sandbox.Policy = { grants = { { path = "a//b", letters = "xr" } }, profiles = { "system" } }
  local paths: {string:Seatbelt.Path} = { ["a//b"] = { path = "/real", directory = false } }
  local out = compile(policy, paths)
  assert(out.parameters.PATH_1 == "/real")
  assert(policy.grants[1].path == "a//b" and policy.grants[1].letters == "xr")
  assert(policy.profiles[1] == "system" and paths["a//b"].path == "/real")
end

local function test_a_terminal_grants_its_slave_and_dev_tty_by_parameter_and_nothing_otherwise()
  local without = compile({ profiles = { "system" } })
  assert(not without.text:find("/dev/tty", 1, true) and without.parameters.TTY == nil, without.text)
  local out = (assert(Seatbelt.compile({}, { paths = {}, terminal = "/dev/ttys004" })))
  assert(out.text == BASE .. [[(allow file-read-data file-write-data file-ioctl (literal (param "TTY")))
(allow file-read-data file-write-data file-ioctl (literal "/dev/tty"))
(allow file-read-data (literal "/dev"))
]], out.text)
  assert(out.parameters.TTY == "/dev/ttys004")
  assert(not out.text:find("ttys004", 1, true), out.text)
  local why: string
  out, why = Seatbelt.compile({}, { paths = {}, terminal = "ttys004" })
  assert(out == nil and why:find("terminal needs an absolute canonical path", 1, true), why)
end
