--- The rules a test module's `policy` declaration ([`cosmic.test`]'s `Policy`) is held to, as the build reads it
--- without running the module: the data a declaration holds, and the [`Declared`] it stands for. [`cosmic.test`] cannot
--- be required here -- the writer's identity would then hold it -- so the translation of a policy into a declaration is
--- written twice, and the worker holds the one to the other: a module whose `policy` call was handed anything but what
--- this reads fails to load, and cosmic/test_policy_test.tl holds both to the same cases.
---
--- Reading the call off a syntax tree is [`build.syntax_analyzer`]'s: it ends
--- in a [`policy_rules.PolicyData`] and the rules here.

local cache_names = require("build.cache_names")
local host_names = require("build.host_names")

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
    caches: {string}
    --- The files of the project root's parent directory a policy
    --- grants (`/parent/<file>`), relative to it.
    mut parent?: {string}
    --- The host requirements a policy declares ([`Test.policy`]'s
    --- `requires`), as written.
    mut requires: {string}
  end

  --- What a `policy` declaration ([`cosmic.test`]'s `Policy`) holds, as the
  --- build reads it from the source.
  record PolicyData
    profiles?: {string}
    isolate?: {string}
    promises?: {string}
    connect?: {string}
    loopback?: {string}
    env?: {string}
    grants?: {{string:string}}
    set_env?: {string:string}
    set_env_digests?: {string:string}
    limits?: {string:integer}
    tmp?: boolean
    user?: integer
    group?: integer
    database?: string
    requires?: {string}
  end

  --- What the field `name` of a `policy` declaration takes: a list of string literals ("list"), a table of names to
  --- string literals ("map"), `true` or `false` ("flag"), a list of tables of string literals ("grants"), a table of
  --- integers ("limits"), an integer ("id") or a string ("string"); nil for a name that is no field.
  kind_of: function(name: string): string?

  --- The names of the fields of a `policy` declaration, sorted and joined by ", ".
  field_list: function(): string

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

--- Why `host` may not be declared in `loopback`, or "" when it may: a
--- dotted quad of 127/8, `127.a.b.c`, each part decimal, 0 to 255,
--- with no leading zero. Strict: a name a lookup might answer
--- elsewhere, `localhost` or `::1`, a shortened or octal spelling,
--- `0.0.0.0`, a range or `*` is none; nor is a spelling no request's
--- host is (`127.0.0.1:8080`, whose port a request's host leaves out).
local function loopback_trouble(host: string): string
  local refused = string.format("loopback %q: %s", host, LOOPBACK_ONLY)
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a ~= "127" then return refused end
  assert(b ~= nil and c ~= nil and d ~= nil, "a match sets every capture")
  for _, part in ipairs({ b, c, d }) do
    if #part > 3 or (#part > 1 and part:sub(1, 1) == "0") or assert(tonumber(part), "digits spell a number") > 255 then
      return refused
    end
  end
  return ""
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

local fields <const>: {string: string} = {
  profiles = "list", grants = "grants", isolate = "list", promises = "list",
  connect = "list", loopback = "list", env = "list", set_env = "map",
  set_env_digests = "map", tmp = "flag", limits = "limits", user = "id", group = "id",
  database = "string", requires = "list",
}

local field_names: mut {string} = {}
for name in pairs(fields) do
  field_names[#field_names + 1] = name
end
table.sort(field_names)

function policy_rules.kind_of(name: string): string?
  return fields[name]
end

function policy_rules.field_list(): string
  return table.concat(field_names, ", ")
end

--- Why `relative`, the part of a `/parent/` grant after the prefix, names no
--- file of the parent directory a grant may hold, or "": the one rule of
--- cosmic/test.tl's `needs_of`, which this module cannot require.
local function parent_fault(relative: string): string
  if relative == "" then return "names no file" end
  if relative:find("\0", 1, true) then return "holds a NUL" end
  if relative:find("$", 1, true) then return "holds a $" end
  if relative:sub(-1) == "/" then return "ends in a \"/\": it names a file, not a directory" end
  for name in (relative .. "/"):gmatch("([^/]*)/") do
    if name == "" then return "has an empty name" end
    if name == "." or name == ".." then return "has a \"" .. name .. "\" name" end
  end
  return ""
end

--- The declaration the policy `data` stands for ([`Test.needs_of`] of
--- cosmic.test, whose refusals these are): nil and why where it is none.
function policy_rules.declared(data: policy_rules.PolicyData, line: integer): policy_rules.Declared?, string
  local parents: mut {string} = {}
  local out: policy_rules.Declared = {
    line = line, reads = {}, host = {}, env = {}, network = {},
    tool = false, lua = false, nests = false, noexec = false, store = false,
    system = false, caches = {}, requires = {}, parent = parents,
  }
  local not_yet = " is not yet taken: a worker is held to, and a key made of, what a " ..
    "policy's paths, profiles and variables say, and nothing holds a test to this"
  local bin, cosmic, proc = false, false, false
  for _, profile in ipairs(data.profiles or {}) do
    if profile == "system" then
      out.system = true
    elseif profile == "cosmic" then
      cosmic = true
    elseif profile == "proc" then
      proc = true
    else
      return nil, "profiles: no profile " .. profile .. "; the profiles are cosmic, proc, system"
    end
  end
  for i, grant in ipairs(data.grants or {}) do
    local at = "grants[" .. tostring(i) .. "]"
    local path, letters = grant.path, grant.letters
    if path == nil or path == "" then return nil, at .. ".path takes a path" end
    if letters == nil or letters == "" or letters:find("^r?w?x?c?u?$") == nil then
      return nil, at .. ".letters takes letters of rwxcu, in that order"
    end
    local named = path:match("^/cache/(.*)$")
    local above = path:match("^/parent/(.*)$")
    if path == "o/cosmic.db" then
      if letters ~= "r" or grant.from ~= nil then
        return nil, at .. ".path o/cosmic.db is the store, granted " ..
          "{ path = \"o/cosmic.db\", letters = \"r\" } with no from"
      end
      out.store = true
    elseif path == "o/bin" then
      if letters ~= "rx" or grant.from ~= nil then
        return nil, at .. ".path o/bin is the directory the program is in, granted " ..
          "{ path = \"o/bin\", letters = \"rx\" } with no from, beside the profile \"cosmic\""
      end
      bin = true
    elseif path == "/noexec" then
      if letters ~= "rwc" or grant.from ~= nil then
        return nil, at .. ".path /noexec is the private scratch the harness gives, " ..
          "granted { path = \"/noexec\", letters = \"rwc\" }: writable, never executable, " ..
          "with no from"
      end
      out.noexec = true
    elseif named ~= nil then
      if letters ~= "rwxc" or grant.from ~= nil then
        return nil, at .. ".path /cache/<name> is a host cache, granted " ..
          "{ path = \"/cache/<name>\", letters = \"rwxc\" } with no from"
      end
      if cache_names.names[named] == nil then
        local known: mut {string} = {}
        for name in pairs(cache_names.names) do known[#known + 1] = name end
        table.sort(known)
        return nil, at .. ".path /cache/" .. named .. ": no cache " .. named ..
          "; the caches are " .. table.concat(known, ", ")
      end
      out.caches[#out.caches + 1] = named
    elseif above ~= nil then
      if letters ~= "r" or grant.from ~= nil then
        return nil, at .. ".path /parent/<file> is a file of the project root's parent " ..
          "directory, granted { path = \"/parent/<file>\", letters = \"r\" } with no from"
      end
      local fault = parent_fault(above)
      if fault ~= "" then return nil, at .. ".path /parent/" .. above .. " " .. fault end
      parents[#parents + 1] = above
    else
      if grant.from ~= nil then return nil, at .. ".from" .. not_yet end
      if letters ~= "r" then
        return nil, at .. ".letters \"" .. letters .. "\"" .. not_yet ..
          "; a test reads, with \"r\", what it declares"
      end
      local list = path:sub(1, 1) == "/" and out.host or out.reads
      list[#list + 1] = path
    end
  end
  for _, promise in ipairs(data.promises or {}) do
    if promise == "nest" then
      out.nests = true
    elseif not (promise == "fork" or promise == "jit" or promise == "fattr") then
      return nil, "promises: no promise " .. promise .. "; the promises are fattr, fork, jit, nest"
    end
  end
  if #(data.isolate or {}) > 0 then return nil, "isolate" .. not_yet end
  if next(data.limits or {}) ~= nil then return nil, "limits" .. not_yet end
  if next(data.set_env or {}) ~= nil then return nil, "set_env" .. not_yet end
  if next(data.set_env_digests or {}) ~= nil then
    return nil, "set_env_digests is refused: a digest holds no value to set; " ..
      "a test names the value in set_env"
  end
  if #(data.connect or {}) > 0 then
    return nil, "connect is refused: no test reaches a host but loopback, whose answer no " ..
      "key holds; declare the addresses in loopback and start the service in the test"
  end
  -- A limit decided for good, as cosmic/test.tl's `needs_of` says.
  if data.database ~= nil then
    return nil, "database is refused: the harness chooses the database a worker runs on " ..
      "(a sealed one of its closure, or the whole program's for `store` and `tool`)"
  end
  if data.tmp == false then
    return nil, "tmp = false" .. not_yet .. "; every test has a temporary directory today"
  end
  if data.user ~= nil or data.group ~= nil then
    return nil, (if data.user ~= nil then "user" else "group" end) .. " is refused: the harness " ..
      "chooses the user a worker runs as"
  end
  for _, name in ipairs(data.env or {}) do
    if name == "*" then
      return nil, 'env: a policy names each variable it passes through; no wildcard "*" in a policy'
    end
  end
  if bin and not cosmic then
    return nil, "grants: .path o/bin is the program's directory, granted only beside " ..
      "the profile \"cosmic\"; add the profile, or drop the grant"
  end
  if proc then out.host[#out.host + 1] = "/proc" end
  out.tool, out.lua = cosmic and bin, cosmic and not bin
  if out.lua then
    local beside = if out.store then "o/cosmic.db" elseif out.system then "system" elseif
      #out.caches > 0 then "/cache/" .. out.caches[1] else nil end
    if beside ~= nil then
      return nil, "profiles: \"cosmic\" without the grant of o/bin holds the program to " ..
        "what the module requires, which is refused beside " .. beside ..
        "; grant { path = \"o/bin\", letters = \"rx\" } beside the profile to " ..
        "run the program itself, whose key holds every module it carries"
    end
  end
  out.env = data.env or {}
  out.network = data.loopback or {}
  local fine, trouble = host_names.check(data.requires or {},
    { system = out.system, host = out.host, env = out.env })
  if not fine then return nil, trouble end
  out.requires = data.requires or {}
  return out, ""
end

return policy_rules
