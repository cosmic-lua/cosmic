#!/usr/bin/env cosmic
local rules = require("cosmic.quicksand.proxy.rules")

local function test_parse_rule()
  local h, p = rules.parse_rule("Example.COM:443")
  assert(h == "example.com", "host should lowercase: " .. tostring(h))
  assert(p == 443, "port should parse: " .. tostring(p))
  h, p = rules.parse_rule("example.com")
  assert(h == "example.com" and p == nil, "bare host means any port")
  h, p = rules.parse_rule("example.com:*")
  assert(h == "example.com" and p == nil, "explicit wildcard port")
end
test_parse_rule()

local function test_match()
  local idx = rules.index({
      ["api.example.com:443"] = {},
      ["any.example.com"] = {},
      ["*.github.io"] = {},
      ["*.internal.example.com:8443"] = {},
    })
  assert(rules.match(idx, "api.example.com", 443) ~= nil, "exact host:port")
  assert(rules.match(idx, "API.EXAMPLE.COM", 443) ~= nil, "case-insensitive")
  assert(rules.match(idx, "api.example.com", 80) == nil, "wrong port denied")
  assert(rules.match(idx, "any.example.com", 1234) ~= nil,
    "portless rule matches any port")
  assert(rules.match(idx, "foo.github.io", 443) ~= nil, "suffix wildcard")
  assert(rules.match(idx, "github.io", 443) == nil,
    "bare suffix itself does not match")
  assert(rules.match(idx, "evilgithub.io", 443) == nil,
    "suffix requires a dot boundary")
  assert(rules.match(idx, "a.internal.example.com", 8443) ~= nil,
    "suffix with port")
  assert(rules.match(idx, "a.internal.example.com", 80) == nil,
    "suffix with wrong port denied")
  assert(rules.match(idx, "unlisted.example.net", 80) == nil,
    "unlisted host denied")
end
test_match()

-- A typo'd rule must fail loudly at validation, never degrade to
-- pass-through: this proxy is the security boundary for boxed egress.
local function test_validate_rejects_malformed_rules()
  local cases: {{any}} = {
    {{type = "bearer"}, "token"},
    {{type = "bearer", token = ""}, "token"},
    {{type = "basic", username = "u"}, "password"},
    {{type = "basic", password = "p"}, "username"},
    {{type = "header", header_name = "x"}, "header_value"},
    {{type = "header", header_value = "v"}, "header_name"},
    {{type = "hmac"}, "unknown rule type"},
    {42, "must be a table"},
  }
  for i, case in ipairs(cases) do
    local ok, err = rules.validate({["a.example.com"] = case[1]})
    assert(not ok, "case " .. tostring(i) .. " should fail validation")
    assert(err:find(case[2] as string, 1, true),
      "case " .. tostring(i) .. " error should mention "
      .. tostring(case[2]) .. ", got: " .. err)
  end
end
test_validate_rejects_malformed_rules()

-- A malformed port in a *key* must fail loudly, never silently widen to
-- "any port": in an egress allowlist that is fail-open. parse_rule's
-- tonumber() returns nil for a bad port, which index() treats as ":*".
local function test_validate_rejects_malformed_port_keys()
  local bad_keys = {
    "db.internal:5432x", -- trailing junk
    "db.internal:0", -- out of range (low)
    "db.internal:70000", -- out of range (high)
    "db.internal:5432:6", -- stray extra colon
    "db.internal: 443", -- embedded space
    "*.internal:443x", -- wildcard form, bad port
  }
  for _, key in ipairs(bad_keys) do
    local ok, err = rules.validate({[key] = {} as any})
    assert(not ok, "key should be rejected: " .. key)
    assert(err:find(key, 1, true),
      "error should name the offending key " .. key .. ", got: " .. err)
  end
  -- The widening it prevents: a rejected key never reaches index().
  assert(rules.match(rules.index({["db.internal:5432x"] = {}}),
      "db.internal", 9999) ~= nil,
    "sanity: an unvalidated bad port DOES widen to any port (why we validate)")
end
test_validate_rejects_malformed_port_keys()

-- Well-formed port keys (and the any-port forms) still pass.
local function test_validate_accepts_valid_port_keys()
  local good_keys = {
    "db.internal:5432", "db.internal:1", "db.internal:65535",
    "db.internal", "db.internal:*", "db.internal:", "*.internal:8443",
  }
  for _, key in ipairs(good_keys) do
    local ok, err = rules.validate({[key] = {} as any})
    assert(ok, "key should be accepted: " .. key .. ", got: " .. tostring(err))
  end
end
test_validate_accepts_valid_port_keys()

local function test_validate_accepts_pass_through_and_complete_rules()
  assert(rules.validate({}), "empty allowlist")
  assert(rules.validate({["a.example.com"] = {} as any}), "empty rule table")
  assert(rules.validate({["a.example.com"] = true}), "true rule")
  assert(rules.validate({
        ["a.example.com"] = {type = "bearer", token = "t"} as any,
        ["b.example.com"] = {
          type = "basic", username = "u", password = "p",
        } as any,
        ["c.example.com"] = {
          type = "header", header_name = "x-k", header_value = "v",
        } as any,
      }), "complete rules of every type")
end
test_validate_accepts_pass_through_and_complete_rules()

local function test_auth_header()
  local n, v = rules.auth_header({type = "bearer", token = "tok"})
  assert(n == "Authorization" and v == "Bearer tok", "bearer")
  n, v = rules.auth_header({type = "basic", username = "u", password = "p"})
  assert(n == "Authorization", "basic name")
  -- "dTpw" is base64("u:p")
  assert(v == "Basic dTpw", "basic value, got: " .. tostring(v))
  n, v = rules.auth_header({
      type = "header", header_name = "x-k", header_value = "s",
    })
  assert(n == "x-k" and v == "s", "custom header")
  assert(rules.auth_header({}) == nil, "pass-through injects nothing")
  assert(rules.auth_header(true) == nil, "true injects nothing")
end
test_auth_header()
