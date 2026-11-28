--- What the C checks' salt holds: the bytecode of [`build.c`]'s closure, so a module in it reruns all of them when
--- it changes. The closure reaches [`cosmic.child`], which starts zig, but not JSON, HTTP, TLS, the network or the
--- Tailscale client: an edit to one of them reruns no C check.

local Store = require("cosmic.store")
local _c = require("build.c")

--- Every module `root` requires, directly or through another, by name.
local function closure(root: string): {string: boolean}
  local seen: mut {string: boolean} = { [root] = true }
  local queue: mut {string} = { root }
  local i = 1
  while i <= #queue do
    local name = queue[i]!
    i = i + 1
    local requires, why = Store.requires(name)
    assert(requires ~= nil, name .. ": " .. tostring(why))
    for _, required in ipairs(requires) do
      if seen[required] == nil then
        seen[required] = true
        queue[#queue + 1] = required
      end
    end
  end
  return seen
end

local function test_the_c_checks_closure_holds_no_json_or_network()
  local seen = closure("build.c")
  assert(seen["cosmic.child"] == true and seen["cosmic.internal.relay_config"] == true,
    "the walk reaches the child's start and the relay's config")
  for _, heavy in ipairs({ "cosmic.json", "cosmic.http", "cosmic.tls", "cosmic.net", "cosmic.tailscale" }) do
    assert(seen[heavy] == nil, "build.c's closure holds " .. heavy)
  end
end
