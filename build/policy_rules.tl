--- The rules a test module's `policy` declaration ([`cosmic.test`]'s `Policy`) is held to, as the build reads it
--- without running the module: the data a declaration holds, and the [`Declared`] it stands for. [`cosmic.test`] cannot
--- be required here -- the writer's identity would then hold it -- so the translation of a policy into a declaration is
--- the leaf both require, [`cosmic.internal.test_policy`], and what the build adds is the path and loopback rules, the
--- caches it knows and the host's requirements. A module whose `policy` call was handed anything but what this reads
--- fails to load, and cosmic/test_policy_test.tl holds both reads to the same cases.
---
--- Reading the call off a syntax tree is [`build.syntax_analyzer`]'s: it ends
--- in a [`policy_rules.PolicyData`] and the rules here.

local cache_names = require("build.cache_names")
local host_names = require("build.host_names")
-- A leaf that requires nothing, so it adds no module to what this one reaches.
local Loopback = require("cosmic.internal.loopback")
-- A leaf too: the terms of a policy, which cosmic.test shares.
local TestPolicy = require("cosmic.internal.test_policy")

local record policy_rules
  --- A test module's `policy` declaration ([`cosmic.test`]), read as
  --- data, as the [`Test.Needs`] it stands for -- see `inputs_of` of the analyzers. A flag
  --- it does not make reads as one never declared.
  record Declared
    -- TODO: declare the lists below `mut {string}`, which [`build.plans`] appends to, once [`Test.Needs`] in cosmic/test.tl holds
    -- its lists `mut {string}`: [`build.test_inputs`] builds a [`Declared`] from them.

    --- The line the declaration starts on.
    mut line: integer
    reads: {string}
    host: {string}
    mut env: {string}
    mut network: {string}
    mut tool: boolean
    mut lua: boolean
    mut nests: boolean
    mut noexec: boolean
    mut store: boolean
    mut system: boolean
    --- Whether a key holds the processor's features ([`Test.policy`]'s
    --- `cpu_features`).
    mut cpu_features?: boolean
    --- Whether its tests read the text-derived rows of their closure's store
    --- ([`Test.policy`]'s `store_text`).
    mut store_text?: boolean
    caches: {string}
    --- The files of the project root's parent directory a policy
    --- grants (`/parent/<file>`), relative to it.
    mut parent?: {string}
    --- The host requirements a policy declares ([`Test.policy`]'s
    --- `requires`), as written.
    mut requires: {string}
    --- The seconds a policy gives each test of the module as a longer limit
    --- than the run's own ([`Test.policy`]'s `timeout`); nil for none.
    mut timeout?: integer
  end

  --- What a `policy` declaration holds, as the build reads it from the
  --- source: [`test_policy.Policy`].
  type PolicyData = TestPolicy.Policy
  --- A grant of a [`PolicyData`]: [`test_policy.Grant`].
  type Grant = TestPolicy.Grant
  --- The limits of a [`PolicyData`]: [`test_policy.Limits`].
  type Limits = TestPolicy.Limits

  --- Why `value` is no entry of the list `field` (`reads` or `host`, the grants of the tree and of the host, `env` or
  --- `network`, the loopback addresses) of a declaration, or "": the path rules, the loopback rule. The message names
  --- the field the policy writes.
  entry_trouble: function(field: string, value: string): string

  --- The declaration the policy `data` stands for ([`Test.needs_of`] of cosmic.test, whose refusals these are): nil and
  --- why where it is none. `line` is the line the policy starts on.
  declared: function(data: PolicyData, line: integer): Declared?, string
end

--- The rule a policy's `loopback` is held to, as a refusal names it.
local LOOPBACK_ONLY <const> = "loopback takes loopback addresses 127.a.b.c only: no test " ..
  "reaches another host, whose answer no key holds (::1 and localhost included), so one " ..
  "that needs a service starts its own on 127.0.0.1"

--- Why `host` may not be declared in `loopback`, or "" when it may: it
--- is the one spelling [`cosmic.internal.loopback`]'s `ipv4` takes. A
--- name a lookup might answer elsewhere, `localhost` or `::1`, `*` or
--- `127.0.0.1:8080` (whose port a request's host leaves out) is none.
local function loopback_trouble(host: string): string
  if Loopback.ipv4(host) then return "" end
  return string.format("loopback %q: %s", host, LOOPBACK_ONLY)
end

--- What a host grant of a directory is refused with: the rule.
local HOST_FILES <const> = "a grant of the host names files, or /proc: grant the files the tests read"

--- Why `path`, the path of a grant, is none, or "" when it is one: a
--- path of the tree (`absolute` false), relative to its root, or of the
--- host (`absolute`). Neither climbs with "..", nor is spelled with "." or
--- an empty name, which a match by prefix would read as another path, nor
--- begins a name with "$": no grant takes a variable. A host grant names a
--- file, or /proc (R3): one written as a directory, with a "/" after
--- it, is refused here, and one that is a directory on the host fails its
--- tests as they start ([`build.test_inputs`]' `resolve`).
local function path_trouble(path: string, absolute: boolean): string
  if path == "" then return "an empty path" end
  local quoted = "\"" .. path .. "\""
  if absolute and path:sub(-1) == "/" and path:sub(1, 6) ~= "/proc/" then
    return quoted .. " names a directory; " .. HOST_FILES
  end
  local inner = path:gsub("^/", ""):gsub("/$", "")
  for name in (inner .. "/"):gmatch("([^/]*)/") do
    if name == "" or name == "." or name == ".." then
      return quoted .. " names \"" .. name .. "\"; spell the path plainly"
    end
    if name:sub(1, 1) == "$" then
      return quoted .. " names a variable; no grant takes one, so write the path out"
    end
  end
  return ""
end

--- Why `value` is no entry of the list `field` (`reads` or `host`, the
--- grants of the tree and of the host, `env` or `network`, the
--- loopback addresses) of a declaration, or "": the path rules, the
--- loopback rule. The message names the field the policy writes.
function policy_rules.entry_trouble(field: string, value: string): string
  if field == "network" then
    -- The rule's own words, which name the field and the host.
    return loopback_trouble(value)
  end
  local trouble = ""
  if field == "env" then
    if value == "" then trouble = "an empty name" end
  else
    trouble = path_trouble(value, field == "host")
  end
  if trouble ~= "" then
    return (if field == "env" then "env" else "grants" end) .. ": " .. trouble
  end
  return ""
end

--- Why a host cache's name is none, or "": the caches [`build.cache_names`] knows.
local function cache_fault(name: string): string
  if cache_names.names[name] ~= nil then return "" end
  local known: mut {string} = {}
  for each in pairs(cache_names.names) do known[#known + 1] = each end
  table.sort(known)
  return "no cache " .. name .. "; the caches are " .. table.concat(known, ", ")
end

--- The declaration the policy `data` stands for ([`test_policy.declared`],
--- which [`Test.needs_of`] takes too, with the caches and the host's
--- requirements the build knows): nil and why where it is none.
function policy_rules.declared(data: policy_rules.PolicyData, line: integer): policy_rules.Declared?, string
  local found, trouble = TestPolicy.declared(data, cache_fault)
  if found == nil then return nil, trouble end
  local fine, why = host_names.check(found.requires, { system = found.system, host = found.host, env = found.env })
  if not fine then return nil, why end
  return {
    line = line, reads = found.reads, host = found.host, env = found.env, network = found.network,
    tool = found.tool, lua = found.lua, nests = found.nests, noexec = found.noexec, store = found.store,
    system = found.system, cpu_features = found.cpu_features, store_text = found.store_text,
    caches = found.caches, parent = found.parent, requires = found.requires, timeout = found.timeout,
  }, ""
end

return policy_rules
