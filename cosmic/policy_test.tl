local Json = require("cosmic.json")
local Sandbox = require("cosmic.sandbox")
local PolicyJson = require("cosmic.policy")

--- Why `json` is refused, asserting that it is, and names `field`.
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
  local policy = assert(PolicyJson.decode("{}"))
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
    { '{"connect": ["example.com:00080"]}', "/connect/0" },
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

local function test_merge_checks_a_digest_against_the_value()
  local text = PolicyJson.encode(merged({ set_env = { A = "1" } }))
  local digest = assert(PolicyJson.decode(text))
  local out = merged({ set_env = { A = "1" } }, digest)
  assert(out.set_env.A == "1" and next(out.set_env_digests) == nil)
  local none, why = Sandbox.merge({ set_env = { A = "2" } }, digest)
  assert(none == nil and why:find("set_env_digests \"A\"", 1, true), why)
  local kept = merged(digest)
  assert(kept.set_env.A == nil and kept.set_env_digests.A ~= nil)
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
    assert(PolicyJson.encode(merged(back)) == text, "policy " .. i .. ": " .. text)
    assert(PolicyJson.encode(back) == text, "policy " .. i .. " decoded: " .. text)
  end
end

local function test_encode_raises_for_what_is_not_merged()
  local ok, why = pcall(PolicyJson.encode, { profiles = { "system" } })
  assert(not ok and tostring(why):find("merged", 1, true), tostring(why))
  local bad, trouble = pcall(PolicyJson.encode, { grants = { { path = "a", letters = "z" } } })
  assert(not bad and tostring(trouble):find("/grants/0/letters", 1, true), tostring(trouble))
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
  assert(text == '{"group":1000,"user":1000}', text)
  local none, why = PolicyJson.decode('{"user":"me"}')
  assert(none == nil and why:find("/user", 1, true), why)
  none, why = PolicyJson.decode('{"user":0}')
  assert(none == nil and why:find("never root", 1, true), why)
end
