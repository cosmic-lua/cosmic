--- Worked examples for [`cosmic.policy`], shown by `cosmic docs` and run by
--- `cosmic test`.

local Sandbox = require("cosmic.sandbox")
local PolicyJson = require("cosmic.policy")

local Example = {} -- checked: literal_needs_type

--- A policy read from JSON is checked as it is read: a letter out of
--- order, or a key the policy does not have, is a failure naming the
--- field by its path, never a program that runs with more than
--- its author meant.
function Example.decode()
  local policy = assert(PolicyJson.decode('{"grants":[{"path":"data","letters":"rx"},{"env":"HOME"}],"setup":{"tmp":true}}'))
  local env, grants, setup = Sandbox.env(policy), Sandbox.paths(policy), assert(policy.setup)
  local grant = assert(grants[1])
  print(env[1], grant.letters, setup.tmp) -- HOME  rx  true
  assert(env[1] == "HOME" and grant.letters == "rx" and setup.tmp == true)
  local bad, why = PolicyJson.decode('{"grants":[{"path":"data","letters":"xr"}]}')
  print(why) -- sandbox: $.grants[0].letters: "xr" is not in the order of "rwxcu", each letter once: "rx"
  assert(bad == nil)
  assert(why:find("$.grants[0].letters", 1, true), why)
  local unknown, trouble = PolicyJson.decode('{"network":true}')
  assert(unknown == nil)
  assert(trouble:find("$.network", 1, true), trouble)
end

--- A merged policy as canonical text, the same for the same policy, for
--- a key or a report: a variable set shows as a digest, so the text shows
--- that its value changed and not what it is, and decoding the text gives a
--- policy that encodes to it again.
function Example.encode()
  local merged = assert(Sandbox.union({ grants = { { calls = "jit" }, { calls = "fork" } }, setup = { set_env = { TOKEN = "s3cret" } } }))
  local text = PolicyJson.encode(merged)
  print(text) -- {"grants":[{"calls":"fork"},{"calls":"jit"}],"setup":{"set_env_digests":{"TOKEN":"..."}}}
  assert(text:find('"grants":[{"calls":"fork"},{"calls":"jit"}]', 1, true) ~= nil and not text:find("s3cret", 1, true))
  assert(PolicyJson.encode((assert(PolicyJson.decode(text)))) == text)
end

return Example -- checked: export_not_declared
