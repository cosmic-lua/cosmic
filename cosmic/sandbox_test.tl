local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local sys = require("cosmic.sys")
local stand_in = require("build.stand_in")

--- Why `json` is refused, asserting that it is, and names `field`.
local function refused(json: string, field: string): string
  local policy, why = Sandbox.decode(json)
  assert(policy == nil, json .. " was taken")
  assert(why:find("^sandbox: "), why)
  assert(why:find(field, 1, true), json .. " refused without naming " .. field .. ": " .. why)
  return why
end

--- The merged policy of `p`, which must merge.
local function merged(...: Sandbox.Policy): Sandbox.Policy
  local out, why = Sandbox.merge(...)
  assert(out ~= nil, why)
  return out
end

local function test_decode_reads_every_field()
  local policy = assert(Sandbox.decode([[{
    "profiles": ["system"],
    "grants": [{"path": "data", "letters": "rwxcu", "from": "/srv/data"}],
    "isolate": ["file", "proc"],
    "promises": ["fork", "jit", "fattr", "nest"],
    "connect": ["example.com:443", "*:80", "host:*"],
    "loopback": ["127.0.0.1", "127.1.2.3"],
    "env": ["HOME"],
    "set_env": {"MODE": "fast"},
    "tmp": true,
    "limits": {"open_files": 64, "file_bytes": 0, "cpu_seconds": 9, "processes": 4}
  }]]))
  assert(policy.profiles[1] == "system")
  assert(policy.grants[1].path == "data" and policy.grants[1].letters == "rwxcu")
  assert(policy.grants[1].from == "/srv/data")
  assert(#policy.isolate == 2 and #policy.promises == 4 and #policy.connect == 3)
  assert(policy.loopback[2] == "127.1.2.3" and policy.env[1] == "HOME")
  assert(policy.set_env.MODE == "fast" and policy.tmp == true)
  assert(policy.limits.open_files == 64 and policy.limits.file_bytes == 0)
  assert(policy.limits.cpu_seconds == 9 and policy.limits.processes == 4)
end

local function test_decode_of_an_empty_policy_holds_nothing()
  local policy = assert(Sandbox.decode("{}"))
  assert(policy.grants == nil and policy.tmp == nil and policy.limits == nil)
end

local function test_decode_refusals_name_the_field()
  local cases: {{string}} = {
    { '{"nope": 1}', "/nope" },
    { '{"grants": [{"path": "a", "letters": "r", "also": 1}]}', "/grants/0/also" },
    { '{"grants": [{"path": "a"}]}', "/grants/0/letters" },
    { '{"grants": [{"letters": "r"}]}', "/grants/0/path" },
    { '{"grants": [{"path": "", "letters": "r"}]}', "/grants/0/path" },
    { '{"grants": [{"path": "a", "letters": "r"}, {"path": "b", "letters": "rz"}]}', "/grants/1/letters" },
    { '{"grants": [{"path": "a", "letters": ""}]}', "/grants/0/letters" },
    { '{"grants": [{"path": "a", "letters": "R"}]}', "/grants/0/letters" },
    { '{"grants": [{"path": "a", "letters": "xr"}]}', "/grants/0/letters" },
    { '{"grants": [{"path": "a", "letters": "rr"}]}', "/grants/0/letters" },
    { '{"grants": [{"path": "a", "letters": 1}]}', "/grants/0/letters" },
    { '{"grants": [{"path": "a", "letters": "r", "from": ""}]}', "/grants/0/from" },
    { '{"grants": "a"}', "/grants" },
    { '{"isolate": ["net"]}', "/isolate/0" },
    { '{"promises": ["fork", "ptrace"]}', "/promises/1" },
    { '{"profiles": ["system", "bogus"]}', "/profiles/1" },
    { '{"connect": ["example.com"]}', "/connect/0" },
    { '{"connect": ["example.com:0"]}', "/connect/0" },
    { '{"connect": ["example.com:65536"]}', "/connect/0" },
    { '{"connect": [":80"]}', "/connect/0" },
    { '{"loopback": ["10.0.0.1"]}', "/loopback/0" },
    { '{"loopback": ["127.0.0.256"]}', "/loopback/0" },
    { '{"loopback": ["127.0.0.01"]}', "/loopback/0" },
    { '{"env": ["A=B"]}', "/env/0" },
    { '{"env": [""]}', "/env/0" },
    { '{"set_env": {"A": 1}}', "/set_env/A" },
    { '{"set_env": {"A=B": "1"}}', "/set_env" },
    { '{"set_env_digests": {"A": "xyz"}}', "/set_env_digests/A" },
    { '{"tmp": "yes"}', "/tmp" },
    { '{"limits": {"open_files": 0}}', "/limits/open_files" },
    { '{"limits": {"cpu_seconds": 0}}', "/limits/cpu_seconds" },
    { '{"limits": {"file_bytes": -1}}', "/limits/file_bytes" },
    { '{"limits": {"processes": 0}}', "/limits/processes" },
    { '{"limits": {"open_files": "many"}}', "/limits/open_files" },
    { '{"limits": {"bogus": 1}}', "/limits/bogus" },
    { '[]', "expected record" },
    { 'not json', "json" },
  }
  for _, case in ipairs(cases) do refused(case[1], case[2]) end
end

local function test_a_letters_refusal_names_the_canonical_order()
  assert(refused('{"grants": [{"path": "a", "letters": "xr"}]}', "/grants/0/letters"):find('"rx"', 1, true))
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

local function test_merge_refuses_two_values_for_one_variable_without_saying_them()
  local out = merged({ set_env = { A = "1", B = "2" } }, { set_env = { A = "1", C = "3" } })
  assert(out.set_env.A == "1" and out.set_env.B == "2" and out.set_env.C == "3")
  local none, why = Sandbox.merge({ set_env = { TOKEN = "hunter2" } }, { set_env = { TOKEN = "hunter3" } })
  assert(none == nil and why:find("set_env \"TOKEN\"", 1, true), why)
  assert(not why:find("hunter", 1, true), why)
end

local function test_merge_checks_a_digest_against_the_value()
  local text = Sandbox.encode(merged({ set_env = { A = "1" } }))
  local digest = assert(Sandbox.decode(text))
  local out = merged({ set_env = { A = "1" } }, digest)
  assert(out.set_env.A == "1" and next(out.set_env_digests) == nil)
  local none, why = Sandbox.merge({ set_env = { A = "2" } }, digest)
  assert(none == nil and why:find("set_env_digests \"A\"", 1, true), why)
  local kept = merged(digest)
  assert(kept.set_env.A == nil and kept.set_env_digests.A ~= nil)
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
  local system = assert(Sandbox.profile("system"))
  for _, grant in ipairs(system.grants) do
    assert(grant.path:sub(1, 1) == "/" and grant.from == nil)
    assert(grant.letters == "rx" or grant.letters == "r" or grant.letters == "rw", grant.path)
    assert(sys.stat(grant.path) ~= nil, grant.path .. " is granted but absent")
  end
  local cosmic = assert(Sandbox.profile("cosmic"))
  assert(#cosmic.grants == 1 and cosmic.grants[1].path == assert(Proc.executable()))
  assert(cosmic.grants[1].letters == "rx")
  local none, why = Sandbox.profile("bogus")
  assert(none == nil and why:find("unknown profile \"bogus\"", 1, true), why)
end

local function test_encode_is_canonical_and_keeps_no_value()
  local a = merged({
    grants = { { path = "/b", letters = "x" }, { path = "/a", letters = "r" } },
    promises = { "jit", "fork" }, tmp = true, set_env = { TOKEN = "hunter2" },
    limits = { open_files = 7 }, env = { "Z", "A" },
  })
  local b = merged({
    env = { "A", "Z" }, limits = { open_files = 7 }, set_env = { TOKEN = "hunter2" }, tmp = true,
    promises = { "fork", "jit" }, grants = { { path = "/a", letters = "r" }, { path = "/b", letters = "x" } },
  })
  local text = Sandbox.encode(a)
  assert(text == Sandbox.encode(b), text)
  assert(not text:find("hunter2", 1, true), text)
  local decoded = assert(Json.decode(text))
  assert(type(decoded) == "table")
  assert(text:find('"env":["A","Z"]', 1, true) and text:find('"promises":["fork","jit"]', 1, true), text)
  assert(text:find('"grants":[{"letters":"r","path":"/a"},{"letters":"x","path":"/b"}]', 1, true), text)
  assert(text:find('"limits":{"open_files":7}', 1, true) and text:find('"tmp":true', 1, true), text)
  assert(text:find('"set_env_digests":{"TOKEN":"', 1, true), text)
  assert(Sandbox.encode(merged()) == "{}")
end

local function test_a_value_changing_changes_the_text()
  local one = Sandbox.encode(merged({ set_env = { A = "1" } }))
  local two = Sandbox.encode(merged({ set_env = { A = "2" } }))
  assert(one ~= two)
end

local function test_encode_decode_encode_is_the_identity()
  local policies: {Sandbox.Policy} = {
    {},
    { tmp = true },
    { grants = { { path = "a b", letters = "rwxcu", from = "/h" }, { path = "/x\u{e9}", letters = "c" } },
      isolate = { "file", "proc" }, promises = { "nest", "fattr", "jit", "fork" },
      connect = { "h:1", "*:*" }, loopback = { "127.9.9.9" }, env = { "A", "B" },
      set_env = { K = "v", E = "" }, limits = { open_files = 3, file_bytes = 0, cpu_seconds = 1, processes = 2 },
      tmp = true },
    { profiles = { "cosmic" }, set_env_digests = { X = string.rep("a", 64) } },
  }
  for i, p in ipairs(policies) do
    local text = Sandbox.encode(merged(p))
    local back = assert(Sandbox.decode(text))
    assert(Sandbox.encode(merged(back)) == text, "policy " .. i .. ": " .. text)
    assert(Sandbox.encode(back) == text, "policy " .. i .. " decoded: " .. text)
  end
end

local function test_encode_raises_for_what_is_not_merged()
  local ok, why = pcall(Sandbox.encode, { profiles = { "system" } })
  assert(not ok and tostring(why):find("merged", 1, true), tostring(why))
  local bad, trouble = pcall(Sandbox.encode, { grants = { { path = "a", letters = "z" } } })
  assert(not bad and tostring(trouble):find("/grants/0/letters", 1, true), tostring(trouble))
  assert(Sandbox.encode({}) == "{}")
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
