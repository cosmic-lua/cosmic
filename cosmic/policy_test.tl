local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Sandbox = require("cosmic.sandbox")
local PolicyJson = require("cosmic.policy")
local Test = require("cosmic.test")

--- Why `json` is refused, asserting that it is, and names `field`, a path
--- like `$.grants[0].letters`.
local function refused(json: string, field: string): string
  local policy, why = PolicyJson.decode(json)
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
  local policy = assert(PolicyJson.decode([[{
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
  assert(assert(policy.profiles)[1] == "system")
  assert(assert(policy.grants)[1].path == "data" and assert(policy.grants)[1].letters == "rwxcu")
  assert(assert(policy.grants)[1].from == "/srv/data")
  assert(#assert(policy.isolate) == 2 and #assert(policy.promises) == 4 and #assert(policy.connect) == 3)
  assert(assert(policy.loopback)[2] == "127.1.2.3" and assert(policy.env)[1] == "HOME")
  assert(assert(policy.set_env)["MODE"] == "fast" and policy.tmp == true)
  assert(assert(policy.limits).open_files == 64 and assert(policy.limits).file_bytes == 0)
  assert(assert(policy.limits).cpu_seconds == 9 and assert(policy.limits).processes == 4)
end

local function test_decode_of_an_empty_policy_holds_nothing()
  local policy = assert(PolicyJson.decode("{}"))
  assert(policy.grants == nil and policy.tmp == nil and policy.limits == nil)
end

local function test_decode_refusals_name_the_field()
  local record Refusal
    text: string
    path: string
  end
  local cases: {Refusal} = {
    { text = '{"nope": 1}', path = "$.nope" },
    { text = '{"grants": [{"path": "a", "letters": "r", "also": 1}]}', path = "$.grants[0].also" },
    { text = '{"grants": [{"path": "a"}]}', path = "$.grants[0].letters" },
    { text = '{"grants": [{"letters": "r"}]}', path = "$.grants[0].path" },
    { text = '{"grants": [{"path": "", "letters": "r"}]}', path = "$.grants[0].path" },
    { text = '{"grants": [{"path": "a", "letters": "r"}, {"path": "b", "letters": "rz"}]}',
      path = "$.grants[1].letters" },
    { text = '{"grants": [{"path": "a", "letters": ""}]}', path = "$.grants[0].letters" },
    { text = '{"grants": [{"path": "a", "letters": "R"}]}', path = "$.grants[0].letters" },
    { text = '{"grants": [{"path": "a", "letters": "xr"}]}', path = "$.grants[0].letters" },
    { text = '{"grants": [{"path": "a", "letters": "rr"}]}', path = "$.grants[0].letters" },
    { text = '{"grants": [{"path": "a", "letters": 1}]}', path = "$.grants[0].letters" },
    { text = '{"grants": [{"path": "a", "letters": "r", "from": ""}]}', path = "$.grants[0].from" },
    { text = '{"grants": "a"}', path = "$.grants" },
    { text = '{"isolate": ["net"]}', path = "$.isolate[0]" },
    { text = '{"promises": ["fork", "ptrace"]}', path = "$.promises[1]" },
    { text = '{"profiles": ["system", "bogus"]}', path = "$.profiles[1]" },
    { text = '{"connect": ["example.com"]}', path = "$.connect[0]" },
    { text = '{"connect": ["example.com:0"]}', path = "$.connect[0]" },
    { text = '{"connect": ["example.com:00080"]}', path = "$.connect[0]" },
    { text = '{"connect": ["example.com:65536"]}', path = "$.connect[0]" },
    { text = '{"connect": [":80"]}', path = "$.connect[0]" },
    { text = '{"loopback": ["10.0.0.1"]}', path = "$.loopback[0]" },
    { text = '{"loopback": ["127.0.0.256"]}', path = "$.loopback[0]" },
    { text = '{"loopback": ["127.0.0.01"]}', path = "$.loopback[0]" },
    { text = '{"env": ["A=B"]}', path = "$.env[0]" },
    { text = '{"env": [""]}', path = "$.env[0]" },
    { text = '{"set_env": {"A": 1}}', path = "$.set_env.A" },
    { text = '{"set_env": {"A=B": "1"}}', path = '$.set_env["A=B"]' },
    { text = '{"set_env_digests": {"A": "xyz"}}', path = "$.set_env_digests.A" },
    { text = '{"tmp": "yes"}', path = "$.tmp" },
    { text = '{"limits": {"open_files": 0}}', path = "$.limits.open_files" },
    { text = '{"limits": {"cpu_seconds": 0}}', path = "$.limits.cpu_seconds" },
    { text = '{"limits": {"file_bytes": -1}}', path = "$.limits.file_bytes" },
    { text = '{"limits": {"processes": 0}}', path = "$.limits.processes" },
    { text = '{"limits": {"open_files": "many"}}', path = "$.limits.open_files" },
    { text = '{"limits": {"bogus": 1}}', path = "$.limits.bogus" },
    { text = '[]', path = "want record" },
    { text = 'not json', path = "json" },
  }
  for _, case in ipairs(cases) do refused(case.text, case.path) end
end

local function test_a_letters_refusal_names_the_canonical_order()
  assert(refused('{"grants": [{"path": "a", "letters": "xr"}]}', "$.grants[0].letters"):find('"rx"', 1, true))
end

local function test_merge_checks_a_digest_against_the_value()
  local text = PolicyJson.encode(merged({ set_env = { A = "1" } }))
  local digest = assert(PolicyJson.decode(text))
  local out = merged({ set_env = { A = "1" } }, digest)
  assert(assert(out.set_env).A == "1" and next(assert(out.set_env_digests)) == nil)
  local none, why = Sandbox.merge({ set_env = { A = "2" } }, digest)
  assert(none == nil and why:find("$.set_env_digests.A", 1, true), why)
  local kept = merged(digest)
  assert(assert(kept.set_env).A == nil and assert(kept.set_env_digests).A ~= nil)
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
  local text = PolicyJson.encode(a)
  assert(text == PolicyJson.encode(b), text)
  assert(not text:find("hunter2", 1, true), text)
  local decoded = assert(Json.decode(text))
  assert(type(decoded) == "table")
  assert(text:find('"env":["A","Z"]', 1, true) and text:find('"promises":["fork","jit"]', 1, true), text)
  assert(text:find('"grants":[{"letters":"r","path":"/a"},{"letters":"x","path":"/b"}]', 1, true), text)
  assert(text:find('"limits":{"open_files":7}', 1, true) and text:find('"tmp":true', 1, true), text)
  assert(text:find('"set_env_digests":{"TOKEN":"', 1, true), text)
  assert(PolicyJson.encode(merged()) == "{}")
end

local function test_a_value_changing_changes_the_text()
  local one = PolicyJson.encode(merged({ set_env = { A = "1" } }))
  local two = PolicyJson.encode(merged({ set_env = { A = "2" } }))
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
    local text = PolicyJson.encode(merged(p))
    local back = assert(PolicyJson.decode(text))
    assert(PolicyJson.encode(merged(back)) == text, "policy " .. tostring(i) .. ": " .. text)
    assert(PolicyJson.encode(back) == text, "policy " .. tostring(i) .. " decoded: " .. text)
  end
end

local function test_encode_raises_for_what_is_not_merged()
  Test.raises(function() PolicyJson.encode({ profiles = { "system" } }) end, "merged")
  local bad, trouble = pcall(PolicyJson.encode, { grants = { { path = "a", letters = "z" } } })
  assert(not bad and tostring(trouble):find("$.grants[0].letters", 1, true), tostring(trouble))
  assert(PolicyJson.encode({}) == "{}")
end

local function test_isolate_file_implies_proc_in_the_text()
  local file = PolicyJson.encode(merged({ isolate = { "file" } }))
  assert(file == PolicyJson.encode(merged({ isolate = { "proc", "file" } })), file)
  assert(file:find('"isolate":["file","proc"]', 1, true), file)
  assert(PolicyJson.encode(merged({ isolate = { "proc" } })):find('"isolate":["proc"]', 1, true))
end

local function test_equal_policies_written_differently_encode_alike()
  local a = PolicyJson.encode(merged({ grants = { { path = "/x/", letters = "wr" } }, isolate = { "file" } }))
  local b = PolicyJson.encode(merged({ grants = { { path = "//x/./", letters = "rw" } }, isolate = { "proc", "file" } }))
  assert(a == b, a .. " vs " .. b)
end

local function test_user_and_group_round_trip_and_are_integers()
  local policy = assert(PolicyJson.decode('{"user":1000,"group":100}'))
  assert(policy.user == 1000 and policy.group == 100)
  local text = PolicyJson.encode((assert(Sandbox.merge({ user = 1000 }))))
  assert(text == '{"user":1000}', text)
  text = PolicyJson.encode((assert(Sandbox.merge({ user = 1000, group = 100 }))))
  assert(text == '{"group":100,"user":1000}', text)
  local none, why = PolicyJson.decode('{"user":"me"}')
  assert(none == nil and why:find("$.user", 1, true), why)
  none, why = PolicyJson.decode('{"user":0}')
  assert(none == nil and why:find("never root", 1, true), why)
end

local function database_of(tmp: string, text: string): string
  local path = tmp .. "/program.db"
  assert(Fs.write(path, text))
  return path
end

local function test_a_database_is_written_with_its_digest_and_read_back(tmp: string)
  local path = database_of(tmp, "bytes of a database")
  local text = PolicyJson.encode(merged({ database = assert(Sandbox.database(path)) }))
  local digest = Hash.hex_sha256("bytes of a database")
  assert(text == '{"database":{"path":"' .. path .. '","sha256":"' .. digest .. '"}}', text)
  local policy = assert(PolicyJson.decode(text))
  assert(assert(policy.database).path == path)
  assert(PolicyJson.encode(merged(policy)) == text)
end

--- The text names what the database is: another file at the same path is
--- not it, and the text moves with the file.
local function test_a_database_that_changed_is_not_the_one_the_text_names(tmp: string)
  local path = database_of(tmp, "one")
  local before = PolicyJson.encode(merged({ database = assert(Sandbox.database(path)) }))
  database_of(tmp, "two")
  local policy, why = PolicyJson.decode(before)
  assert(policy == nil and why:find("$.database.sha256", 1, true), tostring(why))
  assert(PolicyJson.encode(merged({ database = assert(Sandbox.database(path)) })) ~= before,
    "the digest did not move")
  assert(Fs.remove(path))
  policy, why = PolicyJson.decode(before)
  assert(policy == nil and why:find("$.database", 1, true), tostring(why))
end

local function test_a_database_text_is_held_to_its_shape(tmp: string)
  local path = database_of(tmp, "x")
  refused('{"database":"' .. path .. '"}', "$.database")
  refused('{"database":{"path":"' .. path .. '"}}', "$.database")
  -- the shape fails on the first field in byte order, a missing digest before a later field's fault
  refused('{"database":{"path":"' .. path .. '"},"env":5}', "$.database.sha256: missing")
  refused('{"database":{"path":"rel.db","sha256":"00"}}', "$.database")
  refused('{"database":{"path":"' .. path .. '","sha256":"00","more":1}}', "$.database")
  local ok, trouble = pcall(PolicyJson.encode,
    { database = { path = tmp .. "/absent.db", sha256 = string.rep("0", 64) } })
  assert(not ok and tostring(trouble):find("absent.db", 1, true), tostring(trouble))
end

--- The digest lives in the policy's `database`, so a copy of a checked
--- policy, a merge of it, and its encoding all keep the identity the file
--- had when it was checked: none of them adopts a replacement.
local function test_a_checked_database_keeps_its_digest_through_copies_and_merges(tmp: string)
  local path = database_of(tmp, "one")
  local digest = Hash.hex_sha256("one")
  local checked = assert(PolicyJson.decode(PolicyJson.encode(merged({ database = assert(Sandbox.database(path)) }))))
  assert(assert(checked.database).sha256 == digest)
  local copy: Sandbox.Policy = {}
  for key, value in pairs(checked as {string:any}) do (copy as {string:any})[key] = value end
  local again = merged(copy, { tmp = true })
  assert(assert(again.database).path == path and assert(again.database).sha256 == digest)
  database_of(tmp, "two")
  local ok, trouble = pcall(PolicyJson.encode, again)
  assert(not ok and tostring(trouble):find("has changed since", 1, true), tostring(trouble))
  -- A path alone names no identity, and encoding does not give it one.
  ok, trouble = pcall(PolicyJson.encode, merged({ database = { path = path } }))
  assert(not ok and tostring(trouble):find("Sandbox.database", 1, true), tostring(trouble))
end

--- A digest cannot come apart from its path in a merge: two paths, or
--- two digests, are refused together, and a path with none takes the
--- digest the other policy holds.
local function test_merge_joins_database_digests_with_their_paths(tmp: string)
  local path = database_of(tmp, "one")
  local digest = assert(Sandbox.database(path)).sha256
  assert(digest == Hash.hex_sha256("one"))
  local out = merged({ database = { path = path } }, { database = { path = path, sha256 = digest } })
  assert(assert(out.database).sha256 == digest)
  local other = string.rep("0", 64)
  local none, why = Sandbox.merge({ database = { path = path, sha256 = digest } },
    { database = { path = path, sha256 = other } })
  assert(none == nil and why:find("two digests", 1, true), tostring(why))
  local ok, bad = Sandbox.check({ database = { path = path, sha256 = "XYZ" } })
  assert(not ok and bad:find("$.database.sha256", 1, true), bad)
  local absent, absent_why = Sandbox.database(tmp .. "/absent.db")
  assert(absent == nil and absent_why:find("database", 1, true), tostring(absent_why))
end
