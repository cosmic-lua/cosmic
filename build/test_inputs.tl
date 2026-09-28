--- What a test may read: its effective inputs, the default ones its
--- module's place in the tree gives it and the ones its module declares
--- (`build.inputs`), and what `cosmic test --audit` finds a test read
--- beyond them.
---
--- A test's default inputs are
---
--- - its module's import closure, as source files: its own file and
---   the file of every module it requires, directly or not, as the
---   build's module graph has them, or the declaration file of one
---   only a declaration answers for;
--- - every fuzz corpus (`testdata/fuzz/`, where `build.fuzz` looks),
---   when the closure holds `build.fuzz`; and
--- - a pinned environment, `pinned_env`: what the checker and the
---   fuzzer read of it, and what a process of this program needs.
---
--- Its module declares the rest: paths of the tree (`reads`), of the
--- host (`host`), environment variables (`env`), the network
--- (`network`), processes no sandbox holds (`processes`), the tool
--- itself (`tool`), the tree's projection opened directly (`store`),
--- and the system's own programs and files (`system`). Of them, the
--- closure's modules are always enforced: a worker lets a test
--- `require` no other module of the tree (`build.test_worker`'s
--- `refusal`). A sandboxed worker is held to
--- all of them (`build.test_sandbox`), and its verdict keyed by them
--- (`build.declared_key`); an unsandboxed one is held to nothing else,
--- and keyed by what it was seen to read, and the audit compares them
--- with what observation saw (`build.filesystem_observations`), test
--- by test.

local observations = require("build.filesystem_observations")
-- TODO: take the variables that locate a cache from build.cache_names,
-- moving build.caches' `locating` and `variables` there: this is all
-- this module reads of build.caches, whose lazy require of build.zig
-- puts build/zig.tl in build.declared_key's closure, which every
-- sandboxed verdict's key holds by source (build.test's `key_code`), so
-- an edit to build/zig.tl runs every sandboxed test again though it
-- decides no key.
local caches = require("build.caches")
local type analyzer = require("build.analyzer")
local type inputs = require("build.inputs")
local type positions = require("build.positions")

local type Module = positions.Module

local record test_inputs
  --- What one test module's tests may read.
  record Effective
    --- The import closure's source files, by path of the tree.
    files: {string:boolean}
    --- Paths of the tree, each a file or a directory and all beneath
    --- it: the fuzz corpora, and what the module declares.
    reads: {string}
    --- Absolute paths outside the tree, the same way.
    host: {string}
    --- Environment variables, pinned or declared, by name; `"*"` for
    --- the whole environment.
    env: {string:boolean}
    --- Hosts the tests may reach, by name; `"*"` for any.
    network: {string:boolean}
    processes: boolean
    tool: boolean
    store: boolean
    --- Whether its worker is given the system's own paths
    --- (`observations.worker_unveil`), and its key the host's packages
    --- and system (`declared_key.system_identity`).
    system: boolean
    --- The host caches declared, by name (`build.caches`), and where
    --- they are on this host, once the runner resolves them: empty until
    --- then.
    caches: {string}
    cache_paths: {string}
  end

  --- One input a test read that its effective inputs do not hold,
  --- named by the field of `cosmic.test`'s `Needs` that would declare it:
  --- "reads", "host", "env", "network", "processes", "tool", "store"
  --- or "system".
  record Finding
    field: string
    value: string
  end
end

--- The variables every test may read undeclared, which a sandboxed
--- worker is given pinned: what the checker and the fuzzer read, how a
--- test of the sandbox itself confines what it starts (COSMIC_SANDBOX,
--- `observations.must_confine`), and what a process of the program
--- running the tests reads to run at all
--- (`observations.runtime_environment`).
local pinned_env: {string} = { "TL_DEBUG", "TL_DEBUG_FACTS", "FUZZ_SEED", "FUZZ_ITERS", "FUZZ_CASE",
  "COSMIC_SANDBOX" }
for _, name in ipairs(observations.runtime_environment) do pinned_env[#pinned_env + 1] = name end

--- Where `build.fuzz` keeps the corpus of every property.
local corpora <const> = "testdata/fuzz/"

--- Every module `m` requires, directly or not, and itself, that `by_path`
--- holds -- a module the binary carries rather than the tree is no file
--- of it -- as the files they are read from, sorted; and the declaration
--- file of each it requires that only `declarations`, the tree's
--- declaration files by import path, answers for. Whether `build.fuzz`
--- is among them rides along, and so do the modules' names, sorted.
---
--- `requires` holds only the literal names handed to `require` itself,
--- so a `require` of a computed name -- or, until `build.ast.requires`
--- follows it (the TODO in build/embed.tl), of a literal one through
--- `pcall(require, ...)` -- is not followed: the worker refuses one
--- that names a module of the tree outside this closure
--- (`build.test_worker`), so the miss fails the test rather than
--- leaving its key short.
---
--- The compiler -- `vendor.tl`, derived from vendor/tl/ and its
--- patches -- is no file of it, though build.teal loads it as bytecode
--- (`Store.bytecode("vendor.tl")`) rather than by `require`, so no
--- parse follows it: a key over the closure holds it apart, by its
--- bytecode, in the address of the closure store that carries it beside
--- build.teal (`build.writer`'s `loaded_beside`), as it holds every
--- module of the closure by what the compiler made of it.
local function closure(m: Module, by_path: {string:Module},
                       declarations: {string:string}): {string}, boolean, {string}
  local seen: {string:boolean} = {}
  local files: {string} = {}
  local names: {string} = {}
  local fuzzes = false
  local stack: {Module} = { m }
  while #stack > 0 do
    local here = table.remove(stack)
    if not seen[here.path] then
      seen[here.path] = true
      files[#files + 1] = here.file
      names[#names + 1] = here.path
      for _, name in ipairs(here.requires) do
        local other = by_path[name]
        if name == "build.fuzz" then fuzzes = true end
        if other ~= nil and not seen[name] then
          stack[#stack + 1] = other
        elseif other == nil and declarations[name] ~= nil and not seen[name] then
          seen[name] = true
          files[#files + 1] = declarations[name]
          names[#names + 1] = name
        end
      end
    end
  end
  table.sort(files)
  table.sort(names)
  return files, fuzzes, names
end

--- The names of the modules `m`'s import closure holds, sorted: itself,
--- every module of `by_path` it requires, directly or not, and each it
--- requires that only a declaration of `declarations` answers for --
--- what a worker lets its tests `require` of the tree.
function test_inputs.modules(m: Module, by_path: {string:Module},
                             declarations: {string:string}): {string}
  local _, _, names = closure(m, by_path, declarations)
  return names
end

--- `m`'s default inputs and its declared ones together: `by_path` is
--- every module the build compiled, by path, and `declarations` every
--- declaration file of the tree (`<path>.d.tl`), by import path.
function test_inputs.effective(m: Module, by_path: {string:Module},
                               declarations: {string:string}): test_inputs.Effective
  local out: test_inputs.Effective = {
    files = {}, reads = {}, host = {}, env = {}, network = {},
    processes = false, tool = false, store = false, system = false, caches = {},
    cache_paths = {},
  }
  local files, fuzzes = closure(m, by_path, declarations)
  for _, file in ipairs(files) do out.files[file] = true end
  -- Every corpus, not only the ones the module names: a property's
  -- name may be computed, and corpora are small.
  if fuzzes then out.reads[1] = corpora end
  for _, name in ipairs(pinned_env) do out.env[name] = true end
  local declared: analyzer.Declared = m.inputs
  if declared ~= nil then
    for _, path in ipairs(declared.reads) do out.reads[#out.reads + 1] = path end
    for _, path in ipairs(declared.host) do out.host[#out.host + 1] = path end
    for _, name in ipairs(declared.env) do out.env[name] = true end
    for _, name in ipairs(declared.network) do out.network[name] = true end
    out.processes, out.tool, out.store = declared.processes, declared.tool, declared.store
    out.system = declared.system == true
    -- A cache is declared with the variables that locate it.
    for _, name in ipairs(declared.caches or {}) do
      out.caches[#out.caches + 1] = name
      for _, variable in ipairs(caches.variables(name)) do out.env[variable] = true end
    end
  end
  return out
end

--- `path` with its "." names, empty names and trailing "/" dropped and
--- each ".." taking the name before it, as a declaration spells it:
--- lexically, since a read that climbs is placed by what it resolved
--- to already. "." for a relative path that names nothing else, and
--- "/" for an absolute one.
function test_inputs.plain(path: string): string
  local absolute = path:sub(1, 1) == "/"
  local names: {string} = {}
  for name in path:gmatch("[^/]+") do
    if name == ".." and #names > 0 and names[#names] ~= ".." then
      names[#names] = nil
    elseif name ~= "." and not (name == ".." and absolute) then
      names[#names + 1] = name
    end
  end
  local joined = table.concat(names, "/")
  if absolute then return "/" .. joined end
  return joined == "" and "." or joined
end

--- Whether `path` is `prefix`, or beneath it, a trailing "/" on either
--- aside.
local function beneath(path: string, prefix: string): boolean
  prefix = prefix:gsub("/+$", "")
  path = path:gsub("/+$", "")
  if prefix == "" then return path:sub(1, 1) == "/" end
  return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"
end

--- Whether `path` is a directory some input of `effective` sits
--- beneath, of the tree when `absolute` is false: asking what such a
--- directory is, or where it leads, is part of reaching the input.
local function leads_to(effective: test_inputs.Effective, path: string,
                        absolute: boolean): boolean
  path = path:gsub("/+$", "")
  local function under(input: string): boolean
    return input ~= path and beneath(input, path)
  end
  if absolute then
    for _, input in ipairs(effective.host) do
      if under(input) then return true end
    end
    return path == ""
  end
  if path == "" or path == "." then return true end
  for file in pairs(effective.files) do
    if under(file) then return true end
  end
  for _, input in ipairs(effective.reads) do
    if under(input) then return true end
  end
  return false
end

--- Whether `effective` holds a read of `relative`, a path of the tree,
--- by an observation of `kind` (`build.filesystem_observations`): a
--- file of the closure, beneath a declared path or a corpus, the tool
--- or the projection when they are declared, or -- for a stat, an
--- lstat or a realpath, which ask only what a path is -- a directory an
--- input sits beneath.
function test_inputs.covers_tree(effective: test_inputs.Effective, relative: string,
                                 kind: string): boolean
  if effective.files[relative] then return true end
  for _, input in ipairs(effective.reads) do
    if beneath(relative, input) then return true end
  end
  if effective.tool and relative == "o/bin/cosmic" then return true end
  if effective.store and beneath(relative, "o/cosmic.db") then return true end
  if kind == "s" or kind == "l" or kind == "a" then
    return leads_to(effective, relative, false)
  end
  return false
end

--- Whether `effective` holds a read of `path`, absolute and outside the
--- tree, by an observation of `kind`, as `covers_tree` does a path of it.
function test_inputs.covers_host(effective: test_inputs.Effective, path: string,
                                 kind: string): boolean
  for _, input in ipairs(effective.host) do
    if beneath(path, input) then return true end
  end
  if kind == "s" or kind == "l" or kind == "a" then
    return leads_to(effective, path, true)
  end
  return false
end

--- Whether `effective` holds a read of the variable `name`.
function test_inputs.covers_env(effective: test_inputs.Effective, name: string): boolean
  return effective.env["*"] == true or effective.env[name] == true
end

--- The host a request for `url` names, lowercased: what follows its
--- scheme's slashes up to a port, a path or the end.
local function host_of(url: string): string
  local rest = url:match("^%s*%a[%w+.-]*:/*(.*)$") or url
  local host = rest:match("^%[([^%]]*)%]") or rest:match("^([^/:?#]*)") or ""
  host = host:gsub("^.*@", "")
  return host:lower()
end

--- Whether `effective` holds a request for `url`.
function test_inputs.covers_network(effective: test_inputs.Effective, url: string): boolean
  return effective.network["*"] == true or effective.network[host_of(url)] == true
end

--- Whether `host`, as a `network` declaration names one, is a loopback
--- address or name: `localhost`, `::1`, or a dotted-quad `127.a.b.c`,
--- each part decimal, 0 to 255, with no leading zero. Strict: a name a
--- lookup might answer elsewhere, a shortened or octal spelling,
--- `0.0.0.0`, a range or `*` is not one; nor is a spelling no request's
--- host is (`host_of`, which `covers_network` matches a declaration
--- against whole): not `127.0.0.1:8080`, whose port a request's host
--- leaves out, nor `[::1]`, whose brackets it does.
local function loopback_host(host: string): boolean
  if host == "localhost" or host == "::1" then return true end
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a ~= "127" then return false end
  for _, part in ipairs({ b, c, d }) do
    if #part > 3 or (#part > 1 and part:sub(1, 1) == "0") or tonumber(part) > 255 then
      return false
    end
  end
  return true
end

--- Whether a sandboxed worker of `effective` runs offline, in a network
--- namespace of its own with nothing but its loopback, which is up:
--- when it declares no network, or only loopback hosts
--- (`loopback_host`), which that loopback answers as the host's would.
--- The one answer both the sandbox (`build.test_sandbox`'s `plan`) and
--- the key (`build.declared_key`'s `keyable`) take, since a worker
--- keyed but online would stand on what the host's network answered.
--- Keying a loopback-only worker is sound:
---
--- - a new network namespace reaches only the worker's own processes,
---   and an abstract unix socket is its namespace's alone (core/process.h's
---   `Sandbox`), so what a test reaches there is what it started;
--- - its `lo` carries 127/8, so a connection to a closed port there
---   (127.0.0.1:1, 127.0.0.2:1) is refused as on the host's, and a bind
---   finds no host listener or socket in TIME_WAIT in its way;
--- - whether `::1` is there turns on how the kernel sets up a new
---   namespace's IPv6, which the key holds only in part: the kernel's
---   release (`declared_key.host_identity`), not its boot parameters or
---   sysctls; and
--- - `localhost`, `localhost.` and any name under `.localhost` are
---   answered by curl itself (vendor/curl/lib/vdns/hostip.c), never
---   looked up, for a request of `cosmic.http`; a child program that
---   resolves through libc reads /etc/hosts, a system path only a
---   worker whose module declares `system` is given, and whose key
---   holds the host's system (`declared_key.system_identity`).
---
--- A test that needed a service of the host's on its loopback now fails,
--- rather than standing on a verdict that service gave. Unsandboxed, a
--- request is still an observation no key holds (`build.test`).
function test_inputs.offline(effective: test_inputs.Effective): boolean
  for host in pairs(effective.network) do
    if not loopback_host(host) then return false end
  end
  return true
end

--- Paths, as `reads` or `host` would declare them: each directory that
--- more than `most` of them sit directly in stands for them, with a
--- trailing "/", level by level -- but never the root itself.
local function collapsed(paths: {string}, most: integer): {string}
  local set: {string:boolean} = {}
  for _, path in ipairs(paths) do set[path] = true end
  local changed = true
  while changed do
    changed = false
    local by_parent: {string:{string}} = {}
    for path in pairs(set) do
      local parent = path:gsub("/+$", ""):match("^(.*)/[^/]*$")
      if parent ~= nil and parent ~= "" then
        local members = by_parent[parent] or {}
        by_parent[parent] = members
        members[#members + 1] = path
      end
    end
    for parent, members in pairs(by_parent) do
      if #members > most then
        for _, path in ipairs(members) do set[path] = nil end
        set[parent .. "/"] = true
        changed = true
      end
    end
  end
  -- A path and the same with a "/" after it are one, spelled the
  -- second way; a path beneath another the set keeps is held by it.
  local by_name: {string:string} = {}
  for path in pairs(set) do
    local name = path:gsub("/+$", "")
    if by_name[name] == nil or path:sub(-1) == "/" then by_name[name] = path end
  end
  local out: {string} = {}
  for name, path in pairs(by_name) do
    local held = false
    for other in pairs(by_name) do
      if other ~= name and beneath(name, other) then held = true end
    end
    if not held then out[#out + 1] = path end
  end
  table.sort(out)
  return out
end

--- How many paths directly in one directory a suggestion names before
--- it names the directory instead.
local most_named = 3

--- How many tests a line of the audit names before it counts the rest.
local most_tests = 3

--- How many values of one field a line of the audit names before it
--- counts the rest; the declaration it suggests names them all.
local most_values = 6

--- A list of strings as Teal source.
local function literal_list(values: {string}): string
  local quoted: {string} = {}
  for i, value in ipairs(values) do quoted[i] = string.format("%q", value) end
  return "{ " .. table.concat(quoted, ", ") .. " }"
end

--- The fields of `cosmic.test`'s `Needs`, in the order a suggestion
--- writes them.
local field_order: {string} = {
  "reads", "host", "env", "network", "processes", "tool", "store", "system",
}

--- The audit of one test module, as lines to print: what its tests read
--- that its effective inputs do not hold, field by field with the tests
--- that read it, and the `needs` call that would hold it --
--- what `m` declares already, with what it lacks added. `found` is each
--- of its tests' findings, by test name. Nothing when every test's are
--- none.
function test_inputs.report(m: Module, found: {string:{test_inputs.Finding}}): {string}
  local by_field: {string:{string:{string:boolean}}} = {}
  local names: {string} = {}
  for name, findings in pairs(found) do
    if #findings > 0 then names[#names + 1] = name end
    for _, finding in ipairs(findings) do
      local values = by_field[finding.field] or {}
      by_field[finding.field] = values
      local tests = values[finding.value] or {}
      values[finding.value] = tests
      tests[name] = true
    end
  end
  if #names == 0 then return {} end
  table.sort(names)
  local lines: {string} = {
    string.format("audit: %s (%s): %d of %d tests read what they do not declare",
      m.path, m.file, #names, #m.tests),
  }
  local declared: analyzer.Declared = m.inputs or {
    line = 0, reads = {}, host = {}, env = {}, network = {},
    processes = false, tool = false, store = false, system = false, caches = {},
  }
  -- Each value by the tests that read it, and those tests by the set of
  -- them, so tests that read alike share a line.
  local wanted: {string:{string}} = {}
  local groups: {string:{string:{string}}} = {}
  local group_names: {string} = {}
  for _, field in ipairs(field_order) do
    local values = by_field[field]
    if values ~= nil then
      local listed: {string} = {}
      for value in pairs(values) do listed[#listed + 1] = value end
      table.sort(listed)
      wanted[field] = listed
      for _, value in ipairs(listed) do
        local tests: {string} = {}
        for name in pairs(values[value]) do tests[#tests + 1] = name end
        table.sort(tests)
        local shown: {string} = {}
        for i = 1, math.min(#tests, most_tests) do shown[i] = tests[i] end
        local who = table.concat(shown, ", ") ..
          (#tests > most_tests and (" and " .. (#tests - most_tests) .. " more") or "")
        local group = groups[who]
        if group == nil then
          group = {}
          groups[who] = group
          group_names[#group_names + 1] = who
        end
        local in_field = group[field] or {}
        group[field] = in_field
        in_field[#in_field + 1] = value
      end
    end
  end
  table.sort(group_names)
  for _, who in ipairs(group_names) do
    lines[#lines + 1] = "  " .. who .. ":"
    for _, field in ipairs(field_order) do
      local values = groups[who][field]
      if values ~= nil then
        local shown: {string} = {}
        for i = 1, math.min(#values, most_values) do shown[i] = values[i] end
        lines[#lines + 1] = string.format("    %-12s %s%s", field, table.concat(shown, ", "),
          #values > most_values and (" and " .. (#values - most_values) .. " more") or "")
      end
    end
  end
  -- The declaration that holds it all: what is declared, and the rest.
  local parts: {string} = {}
  local function list_field(field: string, have: {string}, collapse: boolean)
    local all: {string} = {}
    for _, value in ipairs(have) do all[#all + 1] = value end
    for _, value in ipairs(wanted[field] or {}) do all[#all + 1] = value end
    if #all == 0 then return end
    if collapse then
      all = collapsed(all, most_named)
    else
      local set: {string:boolean} = {}
      for _, value in ipairs(all) do set[value] = true end
      all = {}
      -- The whole environment holds every name in it.
      if set["*"] then set = { ["*"] = true } end
      for value in pairs(set) do all[#all + 1] = value end
      table.sort(all)
    end
    parts[#parts + 1] = field .. " = " .. literal_list(all)
  end
  list_field("reads", declared.reads, true)
  list_field("host", declared.host, true)
  list_field("env", declared.env, false)
  local hosts: {string} = {}
  for _, url in ipairs(wanted.network or {}) do hosts[#hosts + 1] = host_of(url) end
  local any_host = false
  for _, host in ipairs(declared.network) do
    if host == "*" then any_host = true end
  end
  if any_host then
    parts[#parts + 1] = "network = true"
  else
    local was = wanted.network
    wanted.network = hosts
    list_field("network", declared.network, false)
    wanted.network = was
  end
  for _, flag in ipairs({ "processes", "tool", "store", "system" }) do
    local on = flag == "processes" and declared.processes or flag == "tool" and declared.tool or
      flag == "store" and declared.store or flag == "system" and declared.system
    if on or wanted[flag] ~= nil then parts[#parts + 1] = flag .. " = true" end
  end
  if #(declared.caches or {}) > 0 then
    parts[#parts + 1] = "caches = " .. literal_list(declared.caches)
  end
  if #parts > 0 then
    lines[#lines + 1] = "  declare: Test.needs { " .. table.concat(parts, ", ") .. " }"
  end
  return lines
end

--- One declaration as text two can be compared by, and one text for
--- each declaration: each field's values in the literal's order,
--- duplicates kept, each quoted (`%q`, which marks where it ends),
--- `network = true` as `"*"`, a flag set as `true`, one line each; ""
--- for none. `line` plays no part.
function test_inputs.canonical(maybe: analyzer.Declared | nil): string
  if maybe == nil then return "" end
  local declared: analyzer.Declared = maybe
  local lines: {string} = {}
  local function list(field: string, values: {string})
    for _, value in ipairs(values) do
      lines[#lines + 1] = field .. " " .. string.format("%q", value)
    end
  end
  list("reads", declared.reads)
  list("host", declared.host)
  list("env", declared.env)
  list("network", declared.network)
  if declared.processes then lines[#lines + 1] = "processes true" end
  if declared.tool then lines[#lines + 1] = "tool true" end
  if declared.store then lines[#lines + 1] = "store true" end
  if declared.system then lines[#lines + 1] = "system true" end
  list("caches", declared.caches or {})
  return table.concat(lines, "\n")
end

--- What a `needs` call was handed, as the build reads a declaration
--- (`build.analyzer`), for `canonical`: nil for none.
function test_inputs.as_declared(needs: inputs.Needs | nil): analyzer.Declared | nil
  if needs == nil then return nil end
  local network: {string} = {}
  local asked = needs.network
  if asked is {string} then
    network = asked
  elseif asked == true then
    network = { "*" }
  end
  return { line = 0, reads = needs.reads or {}, host = needs.host or {},
    env = needs.env or {}, network = network, processes = needs.processes == true,
    tool = needs.tool == true, store = needs.store == true, system = needs.system == true,
    caches = needs.caches or {} }
end

return test_inputs
