--- @public
--- Checks to set as an agent's `before` ([`Agent.Before`]): each says
--- why a call may not run, or nil. They are one layer of policy, the
--- agent's own, over what a call means to do; the sandbox (`sandbox`,
--- cosmic.agent.policy) holds what code that runs can do, whatever it
--- means.
---
--- Each sees the model's tool calls and a snippet's calls of the agent
--- (`caller` "code", named history, store.get, store.put, mcp.servers,
--- mcp.tools or mcp.call) alike: name a snippet's calls too where it is
--- to make them.
---
---     agent.before = Check.all({
---       Check.only({ "run", "history" }),
---       Check.budget({ run = 20 }),
---     })

local type Agent = require("cosmic.agent")
local Sandbox = require("cosmic.sandbox")
local String = require("cosmic.string")

local record Check
end

--- Each of `checks` in turn: the first reason blocks the call.
function Check.all(checks: {Agent.Before}): Agent.Before
  return function(call: Agent.Call): string?
    for _, c in ipairs(checks) do
      local reason = c(call)
      if reason ~= nil then return reason end
    end
    return nil
  end
end

--- Blocks a call of any name not in `names`: a tool, or a snippet's call
--- of the agent, so `{ "run" }` lets a snippet make none, and
--- `{ "run", "history", "mcp.servers", "mcp.tools", "mcp.call" }`
--- lets it query and reach the MCP servers.
function Check.only(names: {string}): Agent.Before
  local named: mut {string: boolean} = {}
  for _, n in ipairs(names) do named[n] = true end
  return function(call: Agent.Call): string?
    if named[call.name] == true then return nil end
    return "the agent may not call " .. call.name
  end
end

--- Blocks the calls of each tool in `counts` past its count: they are
--- counted from when the check is made, so make one an agent. A call it
--- lets by is counted, so put it last in [`Check.all`], where the checks
--- before it have let the call by too. It counts by name, whoever calls:
--- a tool and a snippet's call of the agent (history, for one) are counted apart.
---
---     agent.before = Check.budget({ run = 20, write = 5 })
function Check.budget(counts: {string: integer}): Agent.Before
  local made: mut {string: integer} = {}
  return function(call: Agent.Call): string?
    local most = counts[call.name]
    if most == nil then return nil end
    local n = (made[call.name] or 0) + 1
    if n > most then
      return "the agent has called " .. call.name .. " " .. String.counted(most, "time") .. ", its budget"
    end
    made[call.name] = n
    return nil
  end
end

--- Blocks a call that touches a path (each tool's `paths`) that
--- `policy` does not permit ([`Sandbox.permits`], from the call's
--- directory): each path by its real name, a file made asking `c` of its
--- directory. A tool that says no paths
--- passes, and run says none, though its snippets reach what the
--- sandbox lets them: hold those with the sandbox, or [`Check.only`]. A
--- snippet's call of the agent has none.
---
---     agent.before = Check.paths({ grants = { { path = cwd, letters = "rwc" }, { path = "/usr", letters = "r" } } })
function Check.paths(policy: Sandbox.Policy): Agent.Before
  return function(call: Agent.Call): string?
    -- As the tools ask: each action of a path at the real name the one before gave.
    local real_of: mut {string: string} = {}
    for _, t in ipairs(call.paths) do
      local real, why = Sandbox.permits(policy, real_of[t.path] or t.path, t.action, call.cwd)
      if real == nil then
        return "the agent may not " .. t.action .. " " .. t.path .. ": " .. tostring(why)
      end
      real_of[t.path] = real
    end
    return nil
  end
end

--- Blocks a call unless `yes` says it may run: a UI asks the user in it.
function Check.ask(yes: function(call: Agent.Call): boolean): Agent.Before
  return function(call: Agent.Call): string?
    if yes(call) then return nil end
    return "the user said no to " .. call.name
  end
end

return Check
