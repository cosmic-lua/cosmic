--- The terms of a test module's `policy` ([`Test.policy`]): the fields a
--- policy has, and what it stands for. [`cosmic.test`] translates the table a
--- module hands `policy`, and the build ([`build.policy_rules`]) the one it
--- reads from the source, both through [`test_policy.declared`], so the two
--- cannot drift apart. It requires nothing: every worker loads it, and the
--- build's writer reaches no more for it.
---
---     local TestPolicy = require("cosmic.internal.test_policy")
---     local found = assert(TestPolicy.declared({ profiles = { "system" } }))
---     print(found.system) -- true

local record test_policy
  --- One path a test may reach, and how: [`cosmic.sandbox`]'s [`Grant`].
  record Grant
    --- A path of the tree, relative to its root (the worker's directory),
    --- or an absolute path of the host's.
    mut path?: string
    --- What the test may do there: letters of "rwxcu". Only "r" takes
    --- effect so far.
    mut letters?: string
    --- The host's path where it differs from `path`. Not yet taken.
    mut from?: string
  end

  --- The resource limits of a policy: [`cosmic.sandbox`]'s [`Limits`]. None
  --- is taken yet.
  record Limits
    --- The most descriptors a process may hold open.
    mut open_files?: integer
    --- The most bytes a process may write to one file.
    mut file_bytes?: integer
    --- The CPU seconds a process may spend.
    mut cpu_seconds?: integer
    --- The most processes and threads of the whole sandbox.
    mut processes?: integer
  end

  --- What the tests of one module are held to: the fields of
  --- [`cosmic.sandbox`]'s [`Policy`], which a test module writes in place
  --- of [`Test.Needs`]. Every field is optional. This module cannot require
  --- cosmic.sandbox -- every worker would load it -- so the record is
  --- written out here, and a test holds it to the same fields.
  record Policy
    --- Named policies to join in: "system" (`system` of [`Test.Needs`]),
    --- "cosmic" (`lua`; `tool` with the grant of o/bin beside it) and
    --- "proc" (the host path /proc, read, in `host` of [`Test.Needs`]: the
    --- kernel's process information, every process's entries).
    mut profiles?: {string}
    --- The paths the tests read: a grant of "r" on a path of the tree is
    --- a read of it, on an absolute path a host file.
    mut grants?: {Grant}
    --- How far the worker is isolated. Not yet taken.
    mut isolate?: {string}
    --- What the tests may do beyond their basics: "nest" is `nests`;
    --- "fork", "jit" and "fattr" are accepted and change nothing yet.
    mut promises?: {string}
    --- The hosts the tests reach. Refused: no test reaches a host but
    --- loopback.
    mut connect?: {string}
    --- The loopback addresses the tests reach: `network` of [`Test.Needs`].
    mut loopback?: {string}
    --- The variables passed through: `env` of [`Test.Needs`].
    mut env?: {string}
    --- The variables set, by name. Not yet taken.
    mut set_env?: {string:string}
    --- Digests of values set. Refused: a digest holds no value to set.
    mut set_env_digests?: {string:string}
    --- Whether the tests have a temporary directory of their own, as
    --- every test has: `false` is not yet taken.
    mut tmp?: boolean
    --- The resources the tests may spend. Not yet taken.
    mut limits?: Limits
    --- The user the tests run as. Refused: the harness chooses a worker's.
    mut user?: integer
    --- The group the tests run as. Refused, as `user` is.
    mut group?: integer
    --- The database the tests' program runs on. Refused: the harness
    --- chooses it (a sealed one of the closure, or the program's whole for
    --- `store` and `tool`).
    mut database?: string
    --- What the tests need of the host that no other field says, by name
    --- from a closed table: `portable`, `root`, `unix_socket` (Unix stream
    --- socket creation), `loopback` (a TCP listener and a UDP socket bound
    --- to 127.0.0.1), `path:<absolute path>` and
    --- `program:<name>`, and the Linux-class `sandbox`, `landlock:N`, `userns`,
    --- `nest`, `own_proc` and `proc`. The runner asks the host
    --- once, before any worker starts, and a module whose requirement is
    --- absent is not run: its tests are counted n/a where the platform never
    --- has it and skipped where this host lacks it. Nothing is inferred from
    --- the other fields but one: a module that declares `loopback` addresses
    --- requires `loopback`, which the runner derives from the addresses, so
    --- it need not be written. A name the table does not have or one written twice
    --- fails the build. A `path:` needs a `host` grant of that
    --- path and a `program:` the profile "system" and the variable PATH in
    --- `env`, so the worker can see what the runner found.
    mut requires?: {string}
    --- The most seconds each test of the module may run, whole, from 1 to
    --- 3600, where that is more than the run's own limit (`--timeout`,
    --- COSMIC_TEST_TIMEOUT, 30 by default). For a module whose tests
    --- legitimately run long, such as one that starts `cosmic test` or
    --- builds a program. A test that is slow by accident is investigated,
    --- not given a longer limit. A limit below the run's changes nothing.
    --- The limit a verdict was reached under is part of its key.
    mut timeout?: integer
    --- Whether the tests' outcome may turn on the processor's features:
    --- `cpu_features` of [`Test.Needs`].
    mut cpu_features?: boolean
    --- Whether the tests read text-derived rows of their closure's store:
    --- `store_text` of [`Test.Needs`].
    mut store_text?: boolean
  end

  --- What a [`Policy`] stands for, every list and flag given: the fields of
  --- [`Test.Needs`], a list empty and a flag false where it says none.
  record Declared
    reads: {string}
    host: {string}
    env: {string}
    network: {string}
    caches: {string}
    parent: {string}
    requires: {string}
    tool: boolean
    lua: boolean
    nests: boolean
    noexec: boolean
    store: boolean
    system: boolean
    cpu_features: boolean
    store_text: boolean
    timeout?: integer
  end
end

--- The fields of [`Policy`] and what each takes: a list of strings
--- ("list"), a table of names to strings ("map"), a boolean ("flag"), a
--- list of grants ("grants"), the limits ("limits"), an integer ("id"), whole
--- seconds ("seconds") or a path ("string").
local KINDS <const>: {string:string} = {
  profiles = "list", grants = "grants", isolate = "list", promises = "list",
  connect = "list", loopback = "list", env = "list", set_env = "map",
  set_env_digests = "map", tmp = "flag", limits = "limits", user = "id", group = "id",
  database = "string", requires = "list", timeout = "seconds", cpu_features = "flag",
  store_text = "flag",
}

local names: mut {string} = {}
for name in pairs(KINDS) do names[#names + 1] = name end
table.sort(names)
local NAMES <const> = table.concat(names, ", ")

--- What the field `name` of a [`Policy`] takes, as [`KINDS`] spells it, or
--- nil for a name that is no field.
--- @param name string The field's name
--- @return string|nil What it takes
function test_policy.kind_of(name: string): string?
  return KINDS[name]
end

--- The names of the fields of a [`Policy`], sorted and joined by ", ".
--- @return string The names
function test_policy.field_list(): string
  return NAMES
end

--- The most seconds a policy's `timeout` may name: an hour is longer than
--- any test of the tree needs, so a larger number is a mistake or a slow
--- test hidden.
local MOST_TIMEOUT <const> = 3600

--- Why a `timeout` is none: what the field takes, in a refusal.
--- @return string The refusal
function test_policy.timeout_refused(): string
  return "timeout takes a whole number of seconds from 1 to " .. tostring(MOST_TIMEOUT)
end

--- Why what a policy refuses today is refused: nothing holds a test to
--- it, so a declaration of it would claim more than the test is held to.
local NOT_YET <const> = "is not yet taken: a worker is held to, and a key made of, what a " ..
  "policy's paths, profiles and variables say, and nothing holds a test to this"

--- The grants a policy writes for what [`Test.Needs`] says as a field: the
--- store the worker is given, the private noexec scratch, the program's
--- directory beside the profile "cosmic", a host cache written at its own
--- name, and a file of the project root's parent directory. Each is taken
--- as the field, and other letters or a `from` on its path are refused.
---
--- `o/` in a grant is a name of the policy language for the tree's build
--- directory, not a path in the tree: the harness gives what it names
--- from wherever build/paths.tl puts that directory, the sandbox at its
--- own fixed place. It stays `o/` for good: every module that declares
--- `store` or `tool` spells it, and every verdict key holds it, so
--- another name would move every such key and every such declaration for
--- no change in what a test is given.
local STORE_FORM <const> = ".path o/cosmic.db is the store, granted " ..
  "{ path = \"o/cosmic.db\", letters = \"r\" } with no from"
local BIN_FORM <const> = ".path o/bin is the directory the program is in, granted " ..
  "{ path = \"o/bin\", letters = \"rx\" } with no from, beside the profile \"cosmic\""
local NOEXEC_FORM <const> = ".path /noexec is the private scratch the harness gives, " ..
  "granted { path = \"/noexec\", letters = \"rwc\" }: writable, never executable, with no from"
local CACHE_FORM <const> = ".path /cache/<name> is a host cache, granted " ..
  "{ path = \"/cache/<name>\", letters = \"rwxc\" } with no from"
local PARENT_FORM <const> = ".path /parent/<file> is a file of the project root's parent " ..
  "directory, granted { path = \"/parent/<file>\", letters = \"r\" } with no from"

--- Why `relative`, the part of a `/parent/` grant after the prefix, names no
--- file of the parent directory a grant may hold, or "": it is a plain
--- relative path of files, with no empty, `.` or `..` name, no `$`, no
--- trailing "/" and no NUL.
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

--- The promises a policy makes: "nest" is `nests`; the others are
--- accepted and change nothing, since no worker holds them yet.
local PROMISES <const>: {string:boolean} = { nest = true, fork = true, jit = true, fattr = true }

--- What `policy` stands for, or nil and why, naming the field: reads of
--- the tree and host files (grants of "r"), the variables, loopback
--- addresses, the program (profile "cosmic": `lua`; with the grant of
--- o/bin, `tool`), the system (profile "system"), /proc (profile
--- "proc", in `host`) and nesting (promise "nest"). What it cannot say is
--- refused rather than accepted as a declaration that moves no key:
--- `isolate`, `set_env`, `limits`, a grant of more than "r" or from
--- another path, `tmp = false`. `connect`, `set_env_digests`, `database`,
--- `user` and `group` are refused outright. `cache_fault`, where given,
--- says why a cache's name is none (the build knows the names; a worker
--- does not), or "".
--- @param policy Policy The policy
--- @param cache_fault function|nil Why a cache's name is none, or ""
--- @return Declared|nil What it stands for
--- @return string Why it stands for nothing, naming the field
function test_policy.declared(policy: test_policy.Policy,
                              cache_fault?: function(name: string): string): test_policy.Declared?, string
  local reads: mut {string} = {}
  local host: mut {string} = {}
  local caches: mut {string} = {}
  local parent: mut {string} = {}
  local system, nests, store, noexec, bin, cosmic, proc = false, false, false, false, false, false, false
  for _, profile in ipairs(policy.profiles or {}) do
    if profile == "system" then
      system = true
    elseif profile == "cosmic" then
      cosmic = true
    elseif profile == "proc" then
      proc = true
    else
      return nil, "profiles: no profile " .. profile .. "; the profiles are cosmic, proc, system"
    end
  end
  for i, grant in ipairs(policy.grants or {}) do
    local at = "grants[" .. tostring(i) .. "]"
    local path, letters = grant.path or "", grant.letters or ""
    if path == "" then return nil, at .. ".path takes a path" end
    if letters == "" or letters:find("^r?w?x?c?u?$") == nil then
      return nil, at .. ".letters takes letters of rwxcu, in that order"
    end
    local named = path:match("^/cache/(.*)$")
    local above = path:match("^/parent/(.*)$")
    if path == "o/cosmic.db" then
      if letters ~= "r" or grant.from ~= nil then return nil, at .. STORE_FORM end
      store = true
    elseif path == "o/bin" then
      if letters ~= "rx" or grant.from ~= nil then return nil, at .. BIN_FORM end
      bin = true
    elseif path == "/noexec" then
      if letters ~= "rwc" or grant.from ~= nil then return nil, at .. NOEXEC_FORM end
      noexec = true
    elseif named ~= nil then
      if letters ~= "rwxc" or grant.from ~= nil then return nil, at .. CACHE_FORM end
      if named == "" then return nil, at .. ".path /cache/ names no cache" end
      local fault = if cache_fault ~= nil then cache_fault(named) else "" end
      if fault ~= "" then return nil, at .. ".path /cache/" .. named .. ": " .. fault end
      caches[#caches + 1] = named
    elseif above ~= nil then
      if letters ~= "r" or grant.from ~= nil then return nil, at .. PARENT_FORM end
      local fault = parent_fault(above)
      if fault ~= "" then return nil, at .. ".path /parent/" .. above .. " " .. fault end
      parent[#parent + 1] = above
    else
      if grant.from ~= nil then return nil, at .. ".from " .. NOT_YET end
      if letters ~= "r" then
        return nil, at .. ".letters \"" .. letters .. "\" " .. NOT_YET ..
          "; a test reads, with \"r\", what it declares"
      end
      local list = if path:sub(1, 1) == "/" then host else reads end
      list[#list + 1] = path
    end
  end
  for _, promise in ipairs(policy.promises or {}) do
    if PROMISES[promise] == nil then
      return nil, "promises: no promise " .. promise .. "; the promises are fattr, fork, jit, nest"
    end
    if promise == "nest" then nests = true end
  end
  if #(policy.isolate or {}) > 0 then return nil, "isolate " .. NOT_YET end
  local limits = policy.limits
  if limits ~= nil and (limits.open_files ~= nil or limits.file_bytes ~= nil or
      limits.cpu_seconds ~= nil or limits.processes ~= nil) then
    return nil, "limits " .. NOT_YET
  end
  if next(policy.set_env or {}) ~= nil then return nil, "set_env " .. NOT_YET end
  if next(policy.set_env_digests or {}) ~= nil then
    return nil, "set_env_digests is refused: a digest holds no value to set; " ..
      "a test names the value in set_env"
  end
  if #(policy.connect or {}) > 0 then
    return nil, "connect is refused: no test reaches a host but loopback, whose answer no " ..
      "key holds; declare the addresses in loopback and start the service in the test"
  end
  -- A module's own `database` is a limit decided for good: no test needs
  -- one, and the only coherent meaning is an overlay on the sealed database
  -- the harness gives every worker, which the core's `--database` cannot
  -- layer (doc/roadmap.md holds the shape, should one be wanted).
  if policy.database ~= nil then
    return nil, "database is refused: the harness chooses the database a worker runs on " ..
      "(a sealed one of its closure, or the whole program's for `store` and `tool`)"
  end
  if policy.tmp == false then
    return nil, "tmp = false " .. NOT_YET .. "; every test has a temporary directory today"
  end
  if policy.user ~= nil or policy.group ~= nil then
    return nil, (if policy.user ~= nil then "user" else "group" end) .. " is refused: the harness " ..
      "chooses the user a worker runs as"
  end
  for _, name in ipairs(policy.env or {}) do
    if name == "*" then
      return nil, 'env: a policy names each variable it passes through; no wildcard "*" in a policy'
    end
  end
  if bin and not cosmic then
    return nil, "grants: .path o/bin is the program's directory, " ..
      "granted only beside the profile \"cosmic\"; add the profile, or drop the grant"
  end
  local lua = cosmic and not bin
  if lua then
    local beside = if store then "o/cosmic.db" elseif system then "system" elseif
      #caches > 0 then "/cache/" .. caches[1] else nil end
    if beside ~= nil then
      return nil, "profiles: \"cosmic\" without the grant of o/bin holds the program to " ..
        "what the module requires, which is refused beside " .. beside ..
        "; grant { path = \"o/bin\", letters = \"rx\" } beside the profile to " ..
        "run the program itself, whose key holds every module it carries"
    end
  end
  local timeout = policy.timeout
  if timeout ~= nil and (timeout < 1 or timeout > MOST_TIMEOUT) then
    return nil, test_policy.timeout_refused()
  end
  if proc then host[#host + 1] = "/proc" end
  return {
    reads = reads, host = host, env = policy.env or {}, network = policy.loopback or {}, caches = caches,
    parent = parent, requires = policy.requires or {}, tool = cosmic and bin, lua = lua, nests = nests,
    noexec = noexec, store = store, system = system, cpu_features = policy.cpu_features == true,
    store_text = policy.store_text == true, timeout = timeout,
  }, ""
end

return test_policy
