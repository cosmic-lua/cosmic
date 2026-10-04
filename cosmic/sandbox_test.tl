local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local sys = require("cosmic.sys")
local stand_in = require("build.stand_in")

--- The merged policy of `p`, which must merge.
local function merged(...: Sandbox.Policy): Sandbox.Policy
  local out, why = Sandbox.merge(...)
  assert(out ~= nil, why)
  return out
end

local function test_check_holds_letters_to_the_canonical_order_only_when_exact()
  local grant: Sandbox.Policy = { grants = { { path = "a", letters = "xr" } } }
  assert(Sandbox.check(grant))
  local ok, why = Sandbox.check(grant, true)
  assert(not ok and why:find("^sandbox: pointer \"/grants/0/letters\"") and why:find('"rx"', 1, true), why)
  assert(Sandbox.check({ grants = { { path = "a", letters = "rx" } } }, true))
  local bad, trouble = Sandbox.check({ connect = { "nope" } })
  assert(not bad and trouble:find("/connect/0", 1, true), trouble)
end

local function test_merge_joins_the_letters_of_a_path_in_order()
  local out = merged(
    { grants = { { path = "/a", letters = "x" }, { path = "/b", letters = "c" } } },
    { grants = { { path = "/a", letters = "wr" }, { path = "/b", letters = "ur" } } })
  assert(#out.grants == 2)
  assert(out.grants[1].path == "/a" and out.grants[1].letters == "rwx")
  assert(out.grants[2].path == "/b" and out.grants[2].letters == "rcu")
end

local function test_merge_keeps_a_path_with_another_host_path_apart()
  local out = merged({ grants = {
    { path = "/a", letters = "r", from = "/x" }, { path = "/a", letters = "w" },
    { path = "/a", letters = "x", from = "/x" },
  } })
  assert(#out.grants == 2)
  assert(out.grants[1].from == nil and out.grants[1].letters == "w")
  assert(out.grants[2].from == "/x" and out.grants[2].letters == "rx")
end

local function test_merge_unions_lists_sorted_without_repeats()
  local out = merged(
    { promises = { "jit", "fork" }, env = { "B", "A" }, connect = { "b:1", "a:1" },
      isolate = { "proc" }, loopback = { "127.0.0.2" } },
    { promises = { "fork", "fattr" }, env = { "A", "C" }, connect = { "a:1" },
      isolate = { "file", "proc" }, loopback = { "127.0.0.1" } })
  assert(table.concat(out.promises, ",") == "fattr,fork,jit")
  assert(table.concat(out.env, ",") == "A,B,C")
  assert(table.concat(out.connect, ",") == "a:1,b:1")
  assert(table.concat(out.isolate, ",") == "file,proc")
  assert(table.concat(out.loopback, ",") == "127.0.0.1,127.0.0.2")
end

local function test_merge_answers_every_field_even_for_nothing()
  local out = merged()
  assert(out.profiles == nil and out.tmp == false)
  assert(#out.grants == 0 and #out.isolate == 0 and #out.promises == 0 and #out.connect == 0)
  assert(#out.loopback == 0 and #out.env == 0 and next(out.set_env) == nil)
  assert(next(out.set_env_digests) == nil and out.limits.open_files == nil)
  assert(merged({}, { tmp = false }).tmp == false and merged({ tmp = false }, { tmp = true }).tmp)
end

local function test_merge_agrees_on_one_limit_and_refuses_two()
  local out = merged({ limits = { open_files = 8, cpu_seconds = 3 } },
    { limits = { open_files = 8, file_bytes = 100, processes = 2 } })
  assert(out.limits.open_files == 8 and out.limits.cpu_seconds == 3)
  assert(out.limits.file_bytes == 100 and out.limits.processes == 2)
  for _, field in ipairs({ "open_files", "file_bytes", "cpu_seconds", "processes" }) do
    local a: Sandbox.Limits = {}
    local b: Sandbox.Limits = {}
    if field == "open_files" then a.open_files, b.open_files = 1, 2 end
    if field == "file_bytes" then a.file_bytes, b.file_bytes = 1, 2 end
    if field == "cpu_seconds" then a.cpu_seconds, b.cpu_seconds = 1, 2 end
    if field == "processes" then a.processes, b.processes = 1, 2 end
    local none, why = Sandbox.merge({ limits = a }, { limits = b })
    assert(none == nil and why:find("limits." .. field, 1, true), why)
  end
end

local function test_merge_takes_one_user_and_group_and_refuses_two()
  local out = merged({ user = 1000 }, {})
  assert(out.user == 1000 and out.group == nil, "a group left out is the start's to choose")
  out = merged({ user = 1000 }, { user = 1000, group = 100 })
  assert(out.user == 1000 and out.group == 100)
  assert(merged().user == nil and merged().group == nil)
  local none, why = Sandbox.merge({ user = 1 }, { user = 2 })
  assert(none == nil and why:find("user is given two values", 1, true), why)
  none, why = Sandbox.merge({ user = 1, group = 1 }, { user = 1, group = 2 })
  assert(none == nil and why:find("group is given two values", 1, true), why)
end

local function test_merge_refuses_root_and_a_group_without_a_user()
  for _, policy in ipairs({ { user = 0 }, { user = 4294967295 }, { user = 1, group = 0 } } as {Sandbox.Policy}) do
    local none, why = Sandbox.merge(policy)
    assert(none == nil and why:find("never root", 1, true), why)
  end
  for _, policy in ipairs({ { user = 65534 }, { user = 1, group = 65535 } } as {Sandbox.Policy}) do
    local none, why = Sandbox.merge(policy)
    assert(none == nil and why:find("overflow id", 1, true), why)
  end
  local none, why = Sandbox.merge({ group = 5 })
  assert(none == nil and why:find("/group", 1, true) and why:find("with a user", 1, true), why)
end

local function test_in_pool_is_whether_an_id_is_a_pool_user_s()
  local host = "0 0 4294967295\n"
  assert(Sandbox.in_pool(host, host, 4294963198) and Sandbox.in_pool(host, host, 4294967293))
  assert(not Sandbox.in_pool(host, host, 4294963197) and not Sandbox.in_pool(host, host, 1000))
  -- A namespace that maps no pool has none to collide with.
  assert(not Sandbox.in_pool("0 100000 10\n", "0 100000 10\n", 5))
end

local function test_maps_id_is_whether_a_map_holds_the_id()
  assert(Sandbox.maps_id("0 0 4294967295\n", 1000))
  assert(Sandbox.maps_id("0 100000 1\n1000 1000 1\n", 1000))
  assert(not Sandbox.maps_id("0 100000 65536\n", 70000))
  assert(not Sandbox.maps_id("", 1))
end

local function test_merge_refuses_two_values_for_one_variable_without_saying_them()
  local out = merged({ set_env = { A = "1", B = "2" } }, { set_env = { A = "1", C = "3" } })
  assert(out.set_env.A == "1" and out.set_env.B == "2" and out.set_env.C == "3")
  local none, why = Sandbox.merge({ set_env = { TOKEN = "hunter2" } }, { set_env = { TOKEN = "hunter3" } })
  assert(none == nil and why:find("set_env \"TOKEN\"", 1, true), why)
  assert(not why:find("hunter", 1, true), why)
end

local function test_merge_refuses_values_a_type_does_not_stop()
  local cases: {{any}} = {
    { { profiles = { "bogus" } }, "/profiles/0" },
    { { grants = { { path = "a", letters = "z" } } }, "/grants/0/letters" },
    { { grants = { { path = "a", letters = "" } } }, "/grants/0/letters" },
    { { grants = { { path = "", letters = "r" } } }, "/grants/0/path" },
    { { connect = { "nope" } }, "/connect/0" },
    { { loopback = { "8.8.8.8" } }, "/loopback/0" },
    { { env = { "A=1" } }, "/env/0" },
    { { limits = { open_files = 0 } }, "/limits/open_files" },
  }
  for _, case in ipairs(cases) do
    local none, why = Sandbox.merge(case[1] as Sandbox.Policy)
    assert(none == nil and why:find(case[2] as string, 1, true), why)
  end
end

local function test_merge_takes_letters_in_any_order_where_decode_does_not()
  assert(merged({ grants = { { path = "a", letters = "xr" } } }).grants[1].letters == "rx")
  assert(merged({ grants = { { path = "a", letters = "rrw" } } }).grants[1].letters == "rw")
end

local function test_merge_resolves_profiles_away()
  local out = merged({ profiles = { "cosmic" }, grants = { { path = "/data", letters = "r" } } })
  assert(out.profiles == nil)
  local executable = assert(Proc.executable())
  local found, data = false, false
  for _, grant in ipairs(out.grants) do
    if grant.path == executable and grant.letters == "rx" then found = true end
    if grant.path == "/data" then data = true end
  end
  assert(found and data)
  local none, why = Sandbox.merge({ profiles = { "nope" } })
  assert(none == nil and why:find("profiles/0", 1, true) and why:find("known", 1, true), why)
end

local function test_a_profile_joins_with_the_policys_own_grant_of_the_same_path()
  local executable = assert(Proc.executable())
  local out = merged({ profiles = { "cosmic" }, grants = { { path = executable, letters = "w" } } })
  local count = 0
  for _, grant in ipairs(out.grants) do
    if grant.path == executable then
      count = count + 1
      assert(grant.letters == "rwx", grant.letters)
    end
  end
  assert(count == 1)
end

local function test_profile_names_what_it_holds_and_refuses_what_it_has_not()
  -- The "system" profile's paths are the host's, and are checked on a
  -- host that has them (cosmic/child_policy_system_test.tl).
  local system = assert(Sandbox.profile("system"))
  assert(system.profiles == nil and system.grants ~= nil)
  local cosmic = assert(Sandbox.profile("cosmic"))
  assert(#cosmic.grants == 1 and cosmic.grants[1].path == assert(Proc.executable()))
  assert(cosmic.grants[1].letters == "rx")
  local none, why = Sandbox.profile("bogus")
  assert(none == nil and why:find("unknown profile \"bogus\"", 1, true), why)
end

local function test_loaders_names_a_static_program_alone(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local files = assert(Sandbox.loaders(probe))
  assert(#files == 1 and files[1] == assert(sys.realpath(probe)), table.concat(files, " "))
end

local function test_loaders_follows_links_and_a_shebang_chain(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/bin"))
  assert(Fs.symlink(probe, tmp .. "/bin/link"))
  assert(Fs.write(tmp .. "/inner", "#!" .. tmp .. "/bin/link\nprint hi\n", 493))
  assert(Fs.write(tmp .. "/outer", "#! " .. tmp .. "/inner -x\n", 493))
  local files = assert(Sandbox.loaders(tmp .. "/outer"))
  local real = assert(sys.realpath(probe))
  assert(#files == 3, table.concat(files, " "))
  assert(files[1] == assert(sys.realpath(tmp .. "/outer")) and files[2] == assert(sys.realpath(tmp .. "/inner")))
  assert(files[3] == real, files[3])
  -- A relative program is read from the directory given.
  local relative = assert(Sandbox.loaders("outer", tmp))
  assert(#relative == 3 and relative[1] == files[1])
end

local function test_loaders_stops_at_a_cycle_and_refuses_what_is_missing(tmp: string)
  assert(Fs.write(tmp .. "/a", "#!" .. tmp .. "/b\n", 493))
  assert(Fs.write(tmp .. "/b", "#!" .. tmp .. "/a\n", 493))
  local cycle = assert(Sandbox.loaders(tmp .. "/a"))
  assert(#cycle == 2)
  local none, why = Sandbox.loaders(tmp .. "/absent")
  assert(none == nil and why:find("^sandbox: ") and why:find("absent", 1, true), why)
  assert(Fs.write(tmp .. "/dangling", "#!" .. tmp .. "/nowhere\n", 493))
  local dangling, trouble = Sandbox.loaders(tmp .. "/dangling")
  assert(dangling == nil and trouble:find("nowhere", 1, true), trouble)
end

--- An ELF header of `class` (1 or 2) and `data` (1 little, 2 big endian)
--- whose one program header is a PT_INTERP naming `interpreter`, or a
--- PT_LOAD where it is nil.
local function elf(class: integer, data: integer, interpreter: string | nil): string
  local e = data == 1 and "<" or ">"
  local wide = class == 2
  local header_size = wide and 64 or 52
  local entry_size = wide and 56 or 32
  local name = interpreter ~= nil and (interpreter .. "\0") or ""
  local ident = "\127ELF" .. string.char(class, data, 1, 0) .. string.rep("\0", 8)
  local kind = interpreter ~= nil and 3 or 1
  local at = header_size + entry_size
  local header: string
  local entry: string
  if wide then
    header = ident .. string.pack(e .. "I2I2I4I8I8I8I4I2I2I2I2I2I2", 2, 62, 1, 0, header_size, 0, 0,
      header_size, entry_size, 1, 0, 0, 0)
    entry = string.pack(e .. "I4I4I8I8I8I8I8I8", kind, 4, at, 0, 0, #name, #name, 1)
  else
    header = ident .. string.pack(e .. "I2I2I4I4I4I4I4I2I2I2I2I2I2", 2, 3, 1, 0, header_size, 0, 0,
      header_size, entry_size, 1, 0, 0, 0)
    entry = string.pack(e .. "I4I4I4I4I4I4I4I4", kind, at, 0, 0, #name, #name, 4, 1)
  end
  return header .. entry .. name
end

local function test_loaders_reads_an_elf_interpreter_of_every_layout(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/ld"))
  local real = assert(sys.realpath(probe))
  local n = 0
  for _, class in ipairs({ 1, 2 }) do
    for _, data in ipairs({ 1, 2 }) do
      n = n + 1
      local path = tmp .. "/prog" .. n
      assert(Fs.write(path, elf(class, data, probe), 493))
      local files = assert(Sandbox.loaders(path))
      assert(#files == 2 and files[2] == real, "class " .. class .. " data " .. data .. ": " ..
          table.concat(files, " "))
    end
  end
  -- An ELF with no PT_INTERP, as a static one, and one cut short, stand alone.
  assert(Fs.write(tmp .. "/static", elf(2, 1, nil), 493))
  assert(#assert(Sandbox.loaders(tmp .. "/static")) == 1)
  assert(Fs.write(tmp .. "/short", elf(2, 1, probe):sub(1, 70), 493))
  assert(#assert(Sandbox.loaders(tmp .. "/short")) == 1)
  -- One whose interpreter is not there is a program that cannot start.
  assert(Fs.write(tmp .. "/lost", elf(2, 1, tmp .. "/no-loader"), 493))
  local none, why = Sandbox.loaders(tmp .. "/lost")
  assert(none == nil and why:find("no-loader", 1, true), why)
end

local function test_merge_writes_a_path_once_and_joins_its_spellings()
  local out = merged({ grants = {
    { path = "/a//b/./", letters = "r" }, { path = "/a/b", letters = "x" },
    { path = "rel/./x/", letters = "r" }, { path = "./", letters = "w" }, { path = "/", letters = "x" },
    { path = "//", letters = "r" },
  } })
  local seen: {string:string} = {}
  for _, grant in ipairs(out.grants) do seen[grant.path] = grant.letters end
  assert(seen["/a/b"] == "rx" and seen["rel/x"] == "r" and seen["."] == "w", "paths")
  assert(seen["/"] == "rx" and #out.grants == 4)
end

local function test_a_dot_dot_in_a_grant_path_is_refused_naming_the_field()
  for _, path in ipairs({ "..", "/a/../b", "a/b/..", "../x", "/data/x/link/.." }) do
    local ok, why = Sandbox.check({ grants = { { path = path, letters = "r" } } })
    assert(not ok and why:find("/grants/0/path", 1, true) and why:find('".." is not allowed', 1, true), why)
    local none, trouble = Sandbox.merge({ grants = { { path = "ok", letters = "r" }, { path = path, letters = "r" } } })
    assert(none == nil and trouble:find("/grants/1/path", 1, true) and trouble:find("..", 1, true), trouble)
  end
  -- A name that only contains dots is a name.
  assert(merged({ grants = { { path = "/a/..b/c..", letters = "r" } } }).grants[1].path == "/a/..b/c..")
end

local FULL <const> = "         0          0 4294967295\n"

local function test_user_id_takes_a_pool_from_the_top_of_what_a_namespace_maps()
  -- A host maps every id: the pool is the 4096 below the topmost two.
  local first = assert(Sandbox.user_id(FULL, FULL, 0))
  assert(first == 4294967293 - 4095, first)
  assert(assert(Sandbox.user_id(FULL, FULL, 4095)) == 4294967293)
  -- A namespace of 65536 ids keeps clear of nobody and the overflow id.
  local small = "         0     100000      65536\n"
  assert(assert(Sandbox.user_id(small, small, 4095)) == 65533)
  assert(assert(Sandbox.user_id(small, small, 0)) == 65533 - 4095)
  -- No id is root, whatever the serial.
  for _, serial in ipairs({ 0, 1, 4095, 4096, 123456789, 2481 * 4000000 + 7 }) do
    local id = assert(Sandbox.user_id(FULL, FULL, serial))
    assert(id >= first and id <= 4294967293, id)
  end
end

local function test_user_id_differs_for_serials_a_pool_apart_less_than_its_size()
  local seen: {integer:boolean} = {}
  for serial = 100, 100 + 4095 do
    local id = assert(Sandbox.user_id(FULL, FULL, serial))
    assert(not seen[id], "serial " .. serial .. " repeats " .. id)
    seen[id] = true
  end
  assert(assert(Sandbox.user_id(FULL, FULL, 5)) == assert(Sandbox.user_id(FULL, FULL, 5 + 4096)))
end

local function test_user_id_fails_where_the_namespace_maps_no_such_run()
  local few = "         0          0       1000\n"
  local none, why = Sandbox.user_id(few, few, 0)
  assert(none == nil and why:find("^sandbox: ") and why:find("never runs as root", 1, true), why)
  -- A gap in one of the maps, or an empty one.
  local gap = "0 0 1000\n4294965000 4294965000 2294\n"
  assert(Sandbox.user_id(gap, gap, 0) == nil)
  local missing, trouble = Sandbox.user_id("", FULL, 0)
  assert(missing == nil and trouble:find("maps no user or no group", 1, true), trouble)
  -- Both maps must hold the run: one that stops short of it does not.
  assert(Sandbox.user_id(FULL, "0 0 1000\n", 0) == nil)
end

local function test_counts_per_namespace_is_linux_5_17_on()
  for _, release in ipairs({ "5.17.0", "5.17", "5.19.2-generic", "6.0", "6.18.44-fc-v64", "7.1.0", "10.0.0" }) do
    assert(Sandbox.counts_per_namespace(release), release)
  end
  for _, release in ipairs({ "5.16.20", "5.15.0-91-generic", "5.4.0", "4.19.0", "3.10.0-1160", "", "linux", "x.y" }) do
    assert(not Sandbox.counts_per_namespace(release), release)
  end
end

--- A Stat with the mode and kind a reach is judged on, and its owner and
--- group, 0 unless given.
local function described(mode: integer, kind: string, uid?: integer, gid?: integer): sys.Stat
  return { mode = mode, kind = kind as sys.Kind, uid = uid or 0, gid = gid or 0 } as sys.Stat
end

local function test_reach_says_who_gives_a_user_that_owns_nothing_its_rights()
  -- Everyone: 0644 and 0755 files and directories.
  assert(Sandbox.reach("r", described(tonumber("100644", 8), "file")).by == "other")
  assert(Sandbox.reach("rx", described(tonumber("100755", 8), "file")).by == "other")
  assert(Sandbox.reach("r", described(tonumber("40755", 8), "dir")).by == "other")
  -- A directory is read and entered, written and entered.
  assert(Sandbox.reach("r", described(tonumber("40744", 8), "dir")).by == "owner")
  assert(Sandbox.reach("rwc", described(tonumber("40755", 8), "dir")).by == "owner")
  assert(Sandbox.reach("rwc", described(tonumber("40757", 8), "dir")).by == "other")
  assert(Sandbox.reach("w", described(tonumber("100646", 8), "file")).by == "other")
  -- A socket is connected to by writing.
  assert(Sandbox.reach("u", described(tonumber("140666", 8), "socket")).by == "other")
  assert(Sandbox.reach("u", described(tonumber("140755", 8), "socket")).by == "owner")
  -- Only the owner's bits: what an idmapped mount gives.
  assert(Sandbox.reach("rw", described(tonumber("100600", 8), "file")).by == "owner")
  assert(Sandbox.reach("x", described(tonumber("100700", 8), "file")).by == "owner")
end

local function test_reach_of_a_named_user_reads_its_own_class_alone()
  local mine = tonumber("40700", 8)
  -- Its own directory, 0700: the owner's bits are its own.
  assert(Sandbox.reach("rwc", described(mine, "dir", 1000, 1000), 1000, 1000).by == "user")
  -- Another user's, 0700, in no group of its: only an idmapped mount gives it.
  assert(Sandbox.reach("r", described(mine, "dir", 2000, 2000), 1000, 1000).by == "owner")
  -- Its group's, 0750: the group's bits.
  assert(Sandbox.reach("r", described(tonumber("40750", 8), "dir", 2000, 1000), 1000, 1000).by == "user")
  -- Its own file, 0077: open to everyone but its owner, which the kernel
  -- holds to the owner's bits.
  local own = Sandbox.reach("r", described(tonumber("100077", 8), "file", 1000, 1000), 1000, 1000)
  assert(own.by == "" and own.lacks:find("its owner, user 1000,", 1, true), own.lacks)
  -- Its group's file, 0604: the group's bits, not everyone's.
  local grouped = Sandbox.reach("r", described(tonumber("100604", 8), "file", 2000, 1000), 1000, 1000)
  assert(grouped.by == "owner", grouped.by)
  -- No match: as for a user that owns nothing.
  assert(Sandbox.reach("r", described(tonumber("100644", 8), "file", 2000, 2000), 1000, 1000).by == "other")
end

local function test_reach_names_what_even_the_owner_lacks()
  local result = Sandbox.reach("rw", described(tonumber("100400", 8), "file"))
  assert(result.by == "" and result.lacks:find("0400", 1, true) and result.lacks:find("write", 1, true), result.lacks)
  assert(not result.lacks:find("read", 1, true), result.lacks)
  local both = Sandbox.reach("rx", described(tonumber("100200", 8), "file"))
  assert(both.by == "" and both.lacks:find("execute and read", 1, true), both.lacks)
end
