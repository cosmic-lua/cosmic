local Array = require("cosmic.array")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Sandbox = require("cosmic.sandbox")
local PolicyJson = require("cosmic.policy")
local Test = require("cosmic.test")
local PolicyMerge = require("build.policy_merge_fixture")

--- Why `json` is refused, asserting that it is, and names `field`, a path
--- like `$.grants[0].letters`.
local function refused(json: string, field: string): string
  local policy, why = PolicyJson.decode(json)
  assert(policy == nil, json .. " was taken")
  assert(why:find("^sandbox: "), why)
  assert(why:find(field, 1, true), json .. " refused without naming " .. field .. ": " .. why)
  return why
end

local function test_decode_reads_every_field()
  local policy = assert(PolicyJson.decode([[{
    "grants": [{"profile": "system"}, {"path": "data", "letters": "rwxcu", "from": "/srv/data"}, {"calls": "fork"},
      {"calls": "jit"}, {"calls": "fattr"}, {"calls": "nest"},
      {"connect": "example.com:443"}, {"connect": "*:80"}, {"connect": "host:*"},
      {"loopback": "127.0.0.1"}, {"loopback": "127.1.2.3"}, {"env": "HOME"}],
    "isolate": ["file", "proc"],
    "setup": {"set_env": {"MODE": "fast"}, "tmp": true},
    "limits": {"open_files": 64, "file_bytes": 0, "cpu_seconds": 9, "processes": 4}
  }]]))
  assert(Sandbox.profiles(policy)[1] == "system")
  assert(Array.at(Sandbox.paths(policy), 1).path == "data" and Array.at(Sandbox.paths(policy), 1).letters == "rwxcu")
  assert(Array.at(Sandbox.paths(policy), 1).from == "/srv/data")
  assert(#assert(policy.isolate) == 2 and #Sandbox.calls(policy) == 4 and #Sandbox.connects(policy) == 3)
  assert(Sandbox.loopback(policy)[2] == "127.1.2.3" and Sandbox.env(policy)[1] == "HOME")
  assert(assert(assert(policy.setup).set_env)["MODE"] == "fast" and assert(policy.setup).tmp == true)
  assert(assert(policy.limits).open_files == 64 and assert(policy.limits).file_bytes == 0)
  assert(assert(policy.limits).cpu_seconds == 9 and assert(policy.limits).processes == 4)
end

local function test_decode_of_an_empty_policy_holds_nothing()
  local policy = assert(PolicyJson.decode("{}"))
  assert(policy.grants == nil and policy.setup == nil and policy.limits == nil)
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
    { text = '{"grants": [{"letters": "r"}]}', path = "$.grants[0]" },
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
    { text = '{"grants": [{"calls": "fork"}, {"calls": "ptrace"}]}', path = "$.grants[1].calls" },
    { text = '{"grants": [{"path": "a", "letters": "r", "calls": "fork"}]}', path = "$.grants[0]" },
    { text = '{"grants": [{}]}', path = "$.grants[0]" },
    { text = '{"promises": ["fork"]}', path = "$.promises" },
    { text = '{"connect": ["example.com:443"]}', path = "$.connect" },
    { text = '{"grants": [{"connect": "h:1", "calls": "fork"}]}', path = "$.grants[0]" },
    { text = '{"grants": [{"profile": "system"}, {"profile": "bogus"}]}', path = "$.grants[1].profile" },
    { text = '{"grants": [{"connect": "example.com"}]}', path = "$.grants[0].connect" },
    { text = '{"grants": [{"connect": "example.com:0"}]}', path = "$.grants[0].connect" },
    { text = '{"grants": [{"connect": "example.com:00080"}]}', path = "$.grants[0].connect" },
    { text = '{"grants": [{"connect": "example.com:65536"}]}', path = "$.grants[0].connect" },
    { text = '{"grants": [{"connect": ":80"}]}', path = "$.grants[0].connect" },
    { text = '{"grants": [{"loopback": "10.0.0.1"}]}', path = "$.grants[0].loopback" },
    { text = '{"grants": [{"loopback": "127.0.0.256"}]}', path = "$.grants[0].loopback" },
    { text = '{"grants": [{"loopback": "127.0.0.01"}]}', path = "$.grants[0].loopback" },
    { text = '{"grants": [{"env": "A=B"}]}', path = "$.grants[0].env" },
    { text = '{"grants": [{"env": ""}]}', path = "$.grants[0].env" },
    { text = '{"setup": {"set_env": {"A": 1}}}', path = "$.setup.set_env.A" },
    { text = '{"setup": {"set_env": {"A=B": "1"}}}', path = '$.setup.set_env["A=B"]' },
    { text = '{"setup": {"set_env_digests": {"A": "xyz"}}}', path = "$.setup.set_env_digests.A" },
    { text = '{"setup": {"tmp": "yes"}}', path = "$.setup.tmp" },
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
  local text = PolicyJson.encode(PolicyMerge.merged({ setup = { set_env = { A = "1" } } }))
  local digest = assert(PolicyJson.decode(text))
  local out = PolicyMerge.merged({ setup = { set_env = { A = "1" } } }, digest)
  assert(assert(assert(out.setup).set_env).A == "1" and next(assert(assert(out.setup).set_env_digests)) == nil) -- checked: map_field
  local none, why = Sandbox.union({ setup = { set_env = { A = "2" } } }, digest)
  assert(none == nil and why:find("$.setup.set_env_digests.A", 1, true) ~= nil, why)
  local kept = PolicyMerge.merged(digest)
  assert(assert(assert(kept.setup).set_env).A == nil and assert(assert(kept.setup).set_env_digests).A ~= nil) -- checked: map_field*2
end

local function test_encode_is_canonical_and_keeps_no_value()
  local a = PolicyMerge.merged({
    grants = { { path = "/b", letters = "x" }, { path = "/a", letters = "r" }, { calls = "jit" }, { calls = "fork" }, { env = "Z" }, { env = "A" } },
    setup = { tmp = true, set_env = { TOKEN = "hunter2" } },
    limits = { open_files = 7 },
  })
  local b = PolicyMerge.merged({ limits = { open_files = 7 }, setup = { set_env = { TOKEN = "hunter2" }, tmp = true },
    grants = { { path = "/a", letters = "r" }, { path = "/b", letters = "x" }, { calls = "fork" }, { calls = "jit" }, { env = "A" }, { env = "Z" } },
  })
  local text = PolicyJson.encode(a)
  assert(text == PolicyJson.encode(b), text)
  assert(not text:find("hunter2", 1, true), text)
  local decoded, decoded_trouble = Json.decode(text)
  assert(decoded ~= nil, decoded_trouble)
  assert(type(decoded) == "table")
  assert(text:find('"grants":[{"letters":"r","path":"/a"},{"letters":"x","path":"/b"},{"calls":"fork"},{"calls":"jit"},' ..
      '{"env":"A"},{"env":"Z"}]', 1, true), text)
  assert(text:find('"limits":{"open_files":7}', 1, true) and text:find('"tmp":true', 1, true), text)
  assert(text:find('"set_env_digests":{"TOKEN":"', 1, true), text)
  assert(PolicyJson.encode(PolicyMerge.merged()) == "{}")
end

local function test_a_value_changing_changes_the_text()
  local one = PolicyJson.encode(PolicyMerge.merged({ setup = { set_env = { A = "1" } } }))
  local two = PolicyJson.encode(PolicyMerge.merged({ setup = { set_env = { A = "2" } } }))
  assert(one ~= two)
end

local function test_encode_decode_encode_is_the_identity()
  local policies: {Sandbox.Policy} = {
    {},
    { setup = { tmp = true } },
    { grants = { { path = "a b", letters = "rwxcu", from = "/h" }, { path = "/x\u{e9}", letters = "c" }, { calls = "nest" }, { calls = "fattr" }, { calls = "jit" }, { calls = "fork" }, { connect = "h:1" }, { connect = "*:*" }, { loopback = "127.9.9.9" }, { env = "A" }, { env = "B" } },
      isolate = { "file", "proc" },
      setup = { set_env = { K = "v", E = "" }, tmp = true }, limits = { open_files = 3, file_bytes = 0, cpu_seconds = 1, processes = 2 } },
    { setup = { set_env_digests = { X = string.rep("a", 64) } } },
  }
  for i, p in ipairs(policies) do
    local text = PolicyJson.encode(PolicyMerge.merged(p))
    local back = assert(PolicyJson.decode(text))
    assert(PolicyJson.encode(PolicyMerge.merged(back)) == text, "policy " .. tostring(i) .. ": " .. text)
    assert(PolicyJson.encode(back) == text, "policy " .. tostring(i) .. " decoded: " .. text)
  end
end

local function test_encode_raises_for_what_is_not_merged()
  Test.raises(function() PolicyJson.encode({ grants = { { profile = "system" } } }) end, "merged")
  local bad, trouble = pcall(PolicyJson.encode, { grants = { { path = "a", letters = "z" } } })
  assert(not bad and tostring(trouble):find("$.grants[0].letters", 1, true) ~= nil, tostring(trouble))
  assert(PolicyJson.encode({}) == "{}")
end

local function test_isolate_file_implies_proc_in_the_text()
  local file = PolicyJson.encode(PolicyMerge.merged({ isolate = { "file" } }))
  assert(file == PolicyJson.encode(PolicyMerge.merged({ isolate = { "proc", "file" } })), file)
  assert(file:find('"isolate":["file","proc"]', 1, true), file)
  assert(PolicyJson.encode(PolicyMerge.merged({ isolate = { "proc" } })):find('"isolate":["proc"]', 1, true))
end

local function test_equal_policies_written_differently_encode_alike()
  local a = PolicyJson.encode(PolicyMerge.merged({ grants = { { path = "/x/", letters = "wr" } }, isolate = { "file" } }))
  local b = PolicyJson.encode(PolicyMerge.merged({ grants = { { path = "//x/./", letters = "rw" } }, isolate = { "proc", "file" } }))
  assert(a == b, a .. " vs " .. b)
end

local function test_user_and_group_round_trip_and_are_integers()
  local policy = assert(PolicyJson.decode('{"setup":{"user":1000,"group":100}}'))
  assert(assert(policy.setup).user == 1000 and assert(policy.setup).group == 100)
  local text = PolicyJson.encode((assert(Sandbox.union({ setup = { user = 1000 } }))))
  assert(text == '{"setup":{"user":1000}}', text)
  text = PolicyJson.encode((assert(Sandbox.union({ setup = { user = 1000, group = 100 } }))))
  assert(text == '{"setup":{"group":100,"user":1000}}', text)
  local none, why = PolicyJson.decode('{"setup":{"user":"me"}}')
  assert(none == nil and why:find("$.setup.user", 1, true) ~= nil, why)
  none, why = PolicyJson.decode('{"setup":{"user":0}}')
  assert(none == nil and why:find("never root", 1, true) ~= nil, why)
end

local function database_of(tmp: string, text: string): string
  local path = tmp .. "/program.db"
  assert(Fs.write(path, text))
  return path
end

local function test_a_database_is_written_with_its_digest_and_read_back(tmp: string)
  local path = database_of(tmp, "bytes of a database")
  local text = PolicyJson.encode(PolicyMerge.merged({ setup = { database = assert(Sandbox.database(path)) } }))
  local digest = Hash.hex_sha256("bytes of a database")
  assert(text == '{"setup":{"database":{"path":"' .. path .. '","sha256":"' .. digest .. '"}}}', text)
  local policy = assert(PolicyJson.decode(text))
  assert(assert(assert(policy.setup).database).path == path)
  assert(PolicyJson.encode(PolicyMerge.merged(policy)) == text)
end

--- The text names what the database is: another file at the same path is
--- not it, and the text moves with the file.
local function test_a_database_that_changed_is_not_the_one_the_text_names(tmp: string)
  local path = database_of(tmp, "one")
  local before = PolicyJson.encode(PolicyMerge.merged({ setup = { database = assert(Sandbox.database(path)) } }))
  database_of(tmp, "two")
  local policy, why = PolicyJson.decode(before)
  assert(policy == nil and why:find("$.setup.database.sha256", 1, true) ~= nil, tostring(why))
  assert(PolicyJson.encode(PolicyMerge.merged({ setup = { database = assert(Sandbox.database(path)) } })) ~= before,
    "the digest did not move")
  assert(Fs.remove(path))
  policy, why = PolicyJson.decode(before)
  assert(policy == nil and why:find("$.setup.database", 1, true) ~= nil, tostring(why))
end

local function test_a_database_text_is_held_to_its_shape(tmp: string)
  local path = database_of(tmp, "x")
  refused('{"setup":{"database":"' .. path .. '"}}', "$.setup.database")
  refused('{"setup":{"database":{"path":"' .. path .. '"}}}', "$.setup.database.sha256: missing")
  -- a missing digest is named only once the whole shape holds, so any other field's fault comes first
  refused('{"isolate":5,"setup":{"database":{"path":"' .. path .. '"}}}', "$.isolate")
  refused('{"setup":{"database":{"path":"rel.db","sha256":"00"}}}', "$.setup.database")
  refused('{"setup":{"database":{"path":"' .. path .. '","sha256":"00","more":1}}}', "$.setup.database")
  local ok, trouble = pcall(PolicyJson.encode,
    { setup = { database = { path = tmp .. "/absent.db", sha256 = string.rep("0", 64) } } })
  assert(not ok and tostring(trouble):find("absent.db", 1, true) ~= nil, tostring(trouble))
end

--- The digest lives in the policy's `database`, so a copy of a checked
--- policy, a merge of it, and its encoding all keep the identity the file
--- had when it was checked: none of them adopts a replacement.
local function test_a_checked_database_keeps_its_digest_through_copies_and_merges(tmp: string)
  local path = database_of(tmp, "one")
  local digest = Hash.hex_sha256("one")
  local checked = assert(PolicyJson.decode(PolicyJson.encode(PolicyMerge.merged({ setup = { database = assert(Sandbox.database(path)) } }))))
  assert(assert(assert(checked.setup).database).sha256 == digest)
  local copy: Sandbox.Policy = {}
  for key, value in pairs(checked as {string:any}) do (copy as {string:any})[key] = value end -- checked: cast_refused*2
  local again = PolicyMerge.merged(copy, { setup = { tmp = true } })
  assert(assert(assert(again.setup).database).path == path and assert(assert(again.setup).database).sha256 == digest)
  database_of(tmp, "two")
  local ok, trouble = pcall(PolicyJson.encode, again)
  assert(not ok and tostring(trouble):find("has changed since", 1, true) ~= nil, tostring(trouble))
  -- A path alone names no identity, and encoding does not give it one.
  ok, trouble = pcall(PolicyJson.encode, PolicyMerge.merged({ setup = { database = { path = path } } }))
  assert(not ok and tostring(trouble):find("Sandbox.database", 1, true) ~= nil, tostring(trouble))
end

--- A digest cannot come apart from its path in a merge: two paths, or
--- two digests, are refused together, and a path with none takes the
--- digest the other policy holds.
local function test_merge_joins_database_digests_with_their_paths(tmp: string)
  local path = database_of(tmp, "one")
  local digest = assert(Sandbox.database(path)).sha256
  assert(digest == Hash.hex_sha256("one"))
  local out = PolicyMerge.merged({ setup = { database = { path = path } } }, { setup = { database = { path = path, sha256 = digest } } })
  assert(assert(assert(out.setup).database).sha256 == digest)
  local other = string.rep("0", 64)
  local none, why = Sandbox.union({ setup = { database = { path = path, sha256 = digest } } },
    { setup = { database = { path = path, sha256 = other } } })
  assert(none == nil and why:find("two digests", 1, true) ~= nil, tostring(why))
  local ok, bad = Sandbox.check({ setup = { database = { path = path, sha256 = "XYZ" } } })
  assert(not ok and bad:find("$.setup.database.sha256", 1, true) ~= nil, bad)
  local absent, absent_why = Sandbox.database(tmp .. "/absent.db")
  assert(absent == nil and absent_why:find("database", 1, true) ~= nil, tostring(absent_why))
end
