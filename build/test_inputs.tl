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
--- and the system's own programs and files (`system`).
---
--- Whatever it declares, a worker lets a test `require` no module of the
--- tree outside the closure (`build.test_worker`'s `refusal`). A
--- sandboxed worker is held to all the declared inputs
--- (`build.test_sandbox`), and its verdict keyed by them
--- (`build.declared_key`). An unsandboxed one is held to nothing more,
--- and keyed by what it was seen to read. The audit compares the two,
--- test by test, with what observation saw
--- (`build.filesystem_observations`).

local sys = require("cosmic.sys")
local confine = require("build.confine")
local this_program = require("build.this_program")
local cache_names = require("build.cache_names")
local Test = require("cosmic.test")
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
    --- Absolute paths outside the tree, each a file or /proc: as the
    --- module declares them until `resolve` puts each it declares by a
    --- variable (`$NAME/path`) where that variable's value says.
    host: {string}
    --- Environment variables, pinned or declared, by name; `"*"` for
    --- the whole environment.
    env: {string:boolean}
    --- The loopback addresses the tests may reach, by address.
    network: {string:boolean}
    processes: boolean
    tool: boolean
    --- Whether its worker is left unheld by Landlock, so a process it
    --- starts may have a root of its own (`cosmic.test`'s `nests`).
    nests: boolean
    store: boolean
    --- Whether its worker is given the system's own paths
    --- (`confine.worker_unveil`), and its key the host's packages
    --- and system (`declared_key.system_identity`).
    system: boolean
    --- The host caches declared, by name (`build.caches`), and where
    --- they are on this host, once the runner resolves them: empty until
    --- then.
    caches: {string}
    cache_paths: {string}
    --- The variables the module declares by name, in `env` or as the
    --- first name of a `host` path (`$NAME/path`, which declares NAME
    --- too), sorted; and the second alone, by name.
    variables: {string}
    named: {string:boolean}
    --- Once `resolve` has run: each `host` path a variable named, as
    --- the module spells it (`$NAME/path`), by where it resolved; each
    --- of `variables` whose value is an absolute path, by name; and why
    --- a `host` path cannot be given, "" when every one can.
    spelled: {string:string}
    located: {string:string}
    unresolved: string
  end

  --- One input a test read that its effective inputs do not hold,
  --- named by the field of `cosmic.test`'s `Needs` that would declare it:
  --- "reads", "host", "env", "network", "processes", "tool", "nests",
  --- "store" or "system".
  record Finding
    field: string
    value: string
  end
end

--- The variables every test may read undeclared, which a sandboxed
--- worker is given pinned: what the checker and the fuzzer read, how a
--- test of the sandbox itself confines what it starts (COSMIC_SANDBOX,
--- `confine.must_confine`), and what a process of the program
--- running the tests reads to run at all
--- (`this_program.runtime_environment`).
local pinned_env: {string} = { "TL_DEBUG", "TL_DEBUG_FACTS", "FUZZ_SEED", "FUZZ_ITERS", "FUZZ_CASE",
  "COSMIC_SANDBOX" }
for _, name in ipairs(this_program.runtime_environment) do pinned_env[#pinned_env + 1] = name end

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
--- build.teal (`build.closure_store`'s `loaded_beside`), as it holds every
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

--- The name of the variable a `host` path is declared by, `$NAME` or
--- `$NAME/path` (see `cosmic.test`), whose rest follows it at `#name +
--- 2`; "" for a path written out.
local function variable_of(path: string): string
  local name, rest = path:match("^%$([%a_][%w_]*)(.*)$")
  if name == nil or (rest ~= "" and rest:sub(1, 1) ~= "/") then return "" end
  return name
end

--- `m`'s default inputs and its declared ones together: `by_path` is
--- every module the build compiled, by path, and `declarations` every
--- declaration file of the tree (`<path>.d.tl`), by import path.
function test_inputs.effective(m: Module, by_path: {string:Module},
                               declarations: {string:string}): test_inputs.Effective
  local out: test_inputs.Effective = {
    files = {}, reads = {}, host = {}, env = {}, network = {},
    processes = false, tool = false, nests = false, store = false, system = false, caches = {},
    cache_paths = {}, variables = {}, named = {}, spelled = {}, located = {}, unresolved = "",
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
    local variables: {string:boolean} = {}
    for _, path in ipairs(declared.host) do
      out.host[#out.host + 1] = path
      -- A path a variable names declares the variable: the test finds
      -- the path by its value, which its worker is given.
      local name = variable_of(path)
      if name ~= "" then
        out.env[name] = true
        out.named[name] = true
        variables[name] = true
      end
    end
    for _, name in ipairs(declared.env) do
      out.env[name] = true
      if name ~= "*" then variables[name] = true end
    end
    for name in pairs(variables) do out.variables[#out.variables + 1] = name end
    table.sort(out.variables)
    for _, name in ipairs(declared.network) do out.network[name] = true end
    out.processes, out.tool, out.store = declared.processes, declared.tool, declared.store
    out.nests = declared.nests == true
    out.system = declared.system == true
    -- A cache is declared with the variables that locate it.
    for _, name in ipairs(declared.caches or {}) do
      out.caches[#out.caches + 1] = name
      for _, variable in ipairs(cache_names.variables(name)) do out.env[variable] = true end
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

--- The path a `host` path `declared` by a module resolves to, or nil and
--- why it cannot be given. `environment` is the worker's, as the runner
--- sees it, and `roots` are where the tree is (its path and where that
--- resolves). A path cannot be given when it names a variable that is
--- unset, empty, relative or not spelled plainly (a ".", ".." or empty
--- name), or when it is the tree, beneath it or above it.
function test_inputs.resolved(declared: string, environment: {string:string},
                              roots: {string}): string | nil, string
  local path = declared
  local name = variable_of(declared)
  local said = string.format("Test.needs host %q", declared)
  if name ~= "" then
    local rest = declared:sub(#name + 2)
    local value = environment[name]
    if value == nil or value == "" then
      return nil, string.format("%s: %s is %s; a path a variable names needs the variable " ..
        "set to where it is", said, name, value == nil and "unset" or "empty")
    end
    if value:sub(1, 1) ~= "/" then
      return nil, string.format("%s: %s is %q, a relative path; a variable a host path " ..
        "names holds an absolute one", said, name, value)
    end
    -- Spelled plainly, as a declared path is: the test opens the value
    -- as it is spelled, which through a link before a ".." is not where
    -- a key made from the text alone would look.
    if value ~= "/" and test_inputs.plain(value) ~= value:gsub("/$", "") then
      return nil, string.format("%s: %s is %q, which names \".\", \"..\" or an empty " ..
        "name; a variable a host path names holds an absolute path spelled plainly",
        said, name, value)
    end
    path = test_inputs.plain(value .. rest)
  end
  local real = confine.resolution(path)
  for _, root in ipairs(roots) do
    for _, where in ipairs({ path, real }) do
      if where ~= "" and root ~= "" and beneath(where, root) then
        return nil, string.format("%s: %s is the tree's; a path of the tree goes in reads",
          said, path)
      elseif where ~= "" and root ~= "" and beneath(root, where) then
        return nil, string.format("%s: %s holds the tree; declare the paths beneath it " ..
          "the tests read", said, path)
      end
    end
  end
  return path, ""
end

--- Puts each `host` path of `effective` that a variable names where the
--- variable's value in `environment` says (`resolved`), spelling it as
--- declared in `spelled`, and notes where each variable it declares is
--- in `located`. `unresolved` says why a path cannot be given: see
--- `resolved`, whose `roots` this takes, or it is a directory, but for
--- /proc, which `cosmic.test`'s `host` never names.
function test_inputs.resolve(effective: test_inputs.Effective, environment: {string:string},
                             roots: {string})
  local host: {string} = {}
  effective.spelled, effective.located, effective.unresolved = {}, {}, ""
  for _, declared in ipairs(effective.host) do
    local path, trouble = test_inputs.resolved(declared, environment, roots)
    -- A file, or /proc: a directory no key holds by what it holds (R3).
    -- One not there is none, as a file of another platform's is not.
    local st: sys.Stat = nil
    if path ~= nil then
      local found, _ = sys.stat(path)
      st = found
    end
    if st ~= nil and st.kind == "dir" and not beneath(path, "/proc") then
      path, trouble = nil, string.format("Test.needs host %q: %s is a directory; host names " ..
        "files, or /proc: declare the files the tests read", declared, path)
    end
    if path == nil then
      if effective.unresolved == "" then effective.unresolved = trouble end
    else
      host[#host + 1] = path
      if variable_of(declared) ~= "" then
        effective.spelled[test_inputs.plain(path)] = declared
      end
    end
  end
  effective.host = host
  for _, name in ipairs(effective.variables or {}) do
    local value = environment[name]
    if value ~= nil and value:sub(1, 1) == "/" then
      effective.located[name] = test_inputs.plain(value)
    end
  end
end

--- `path`, absolute, as a variable of `effective` (`located`) spells it
--- where it is that variable's value or beneath it -- `$NAME` or
--- `$NAME/rest`, the longest value that holds it -- and `path` itself
--- where none does; only a variable a `host` path names (`named`) where
--- `named_only`.
function test_inputs.spelling(effective: test_inputs.Effective, path: string,
                              named_only?: boolean): string
  local best, best_value: string, string = nil, ""
  for name, value in pairs(effective.located or {}) do
    if (not named_only or (effective.named or {})[name]) and value ~= "/" and
        beneath(path, value) and (#value > #best_value or
        (#value == #best_value and (best == nil or name < best))) then
      best, best_value = name, value
    end
  end
  if best == nil then return path end
  local rest = path:gsub("/+$", ""):sub(#best_value + 1)
  return "$" .. best .. rest
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

--- Whether `effective` holds a request for `url`: one to a loopback
--- address it declares (`cosmic.test`'s `network`).
function test_inputs.covers_network(effective: test_inputs.Effective, url: string): boolean
  return effective.network[host_of(url)] == true
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
  "reads", "host", "env", "network", "processes", "tool", "nests", "store", "system",
}

--- The audit of one test module, as lines to print: what its tests read
--- that its effective inputs do not hold, field by field with the tests
--- that read it, and the `needs` call that would hold it: what `m`
--- declares already, with what it lacks added. `found` is each of its
--- tests' findings, by test name. Nothing when no test has any.
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
    processes = false, tool = false, nests = false, store = false, system = false, caches = {},
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
  -- A host path is a file, or /proc, whatever beneath it was read.
  local host_files: {string} = {}
  for _, path in ipairs(wanted.host or {}) do
    host_files[#host_files + 1] = beneath(path, "/proc") and "/proc" or path
  end
  if wanted.host ~= nil then wanted.host = host_files end
  list_field("host", declared.host, false)
  list_field("env", declared.env, false)
  -- A loopback address is declared; any other host is one no test may
  -- reach (`cosmic.test`'s `network`), which the declaration cannot hold.
  local hosts: {string} = {}
  local beyond: {string:boolean} = {}
  for _, url in ipairs(wanted.network or {}) do
    local host = host_of(url)
    if Test.network_trouble(host) == "" then
      hosts[#hosts + 1] = host
    else
      beyond[host] = true
    end
  end
  local was = wanted.network
  wanted.network = hosts
  list_field("network", declared.network, false)
  wanted.network = was
  local refused: {string} = {}
  for host in pairs(beyond) do refused[#refused + 1] = host end
  table.sort(refused)
  for _, flag in ipairs({ "processes", "tool", "nests", "store", "system" }) do
    local on = flag == "processes" and declared.processes or flag == "tool" and declared.tool or
      flag == "nests" and declared.nests or flag == "store" and declared.store or
      flag == "system" and declared.system
    if on or wanted[flag] ~= nil then parts[#parts + 1] = flag .. " = true" end
  end
  if #(declared.caches or {}) > 0 then
    parts[#parts + 1] = "caches = " .. literal_list(declared.caches)
  end
  if #parts > 0 then
    lines[#lines + 1] = "  declare: Test.needs { " .. table.concat(parts, ", ") .. " }"
  end
  for _, host in ipairs(refused) do
    lines[#lines + 1] = string.format("  reaches %s, beyond loopback, which no test may: " ..
      "serve what it needs on 127.0.0.1 instead", host)
  end
  return lines
end

--- One declaration as text two can be compared by, and one text for
--- each declaration: one line for each value of a field, in the
--- literal's order, duplicates kept, quoted (`%q`, which marks where it
--- ends), and for each flag set, as `true`; "" for none. `line` plays no
--- part.
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
  if declared.nests then lines[#lines + 1] = "nests true" end
  if declared.store then lines[#lines + 1] = "store true" end
  if declared.system then lines[#lines + 1] = "system true" end
  list("caches", declared.caches or {})
  return table.concat(lines, "\n")
end

--- What a `needs` call was handed, as the build reads a declaration
--- (`build.analyzer`), for `canonical`: nil for none.
function test_inputs.as_declared(needs: inputs.Needs | nil): analyzer.Declared | nil
  if needs == nil then return nil end
  return { line = 0, reads = needs.reads or {}, host = needs.host or {},
    env = needs.env or {}, network = needs.network or {}, processes = needs.processes == true,
    tool = needs.tool == true, nests = needs.nests == true, store = needs.store == true, system = needs.system == true,
    caches = needs.caches or {} }
end

return test_inputs
