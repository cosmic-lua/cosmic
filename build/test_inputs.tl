--- What a test may read: its effective inputs, the default ones its
--- module's place in the tree gives it and the ones its module declares
--- ([`build.inputs`]).
---
--- A test's default inputs are
---
--- - its module's import closure, as source files: its own file and
---   the file of every module it requires, directly or not, as the
---   build's module graph has them, or the declaration file of one
---   only a declaration answers for;
--- - every fuzz corpus (`testdata/fuzz/`, where [`build.fuzz`] looks),
---   when the closure holds [`build.fuzz`]; and
--- - a pinned environment, `pinned_env`: what the checker and the
---   fuzzer read of it, and what a process of this program needs.
---
--- Its module declares the rest: paths of the tree (`reads`), of the
--- host (`host`), environment variables (`env`), the network
--- (`network`), the tool itself (`tool`), a root of its own for what it
--- starts (`nests`), the tree's projection opened directly (`store`),
--- and the system's own programs and files (`system`).
---
--- Whatever it declares, a worker lets a test `require` no module of the
--- tree outside the closure ([`build.test_worker`]'s `refusal`). A
--- sandboxed worker is held to all the declared inputs
--- ([`build.test_sandbox`]), and its verdict keyed by them
--- ([`build.declared_key`]). An unsandboxed one is held to nothing more,
--- and keyed by them all the same. A sandboxed test that reads what it
--- does not declare finds nothing there, and fails with its own error.

local sys = require("cosmic.sys")
local confine = require("build.confine")
local this_program = require("build.this_program")
local cache_names = require("build.cache_names")
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
    tool: boolean
    --- Whether it starts this program only to run Lua in it
    --- ([`cosmic.test`]'s `lua`): its closure holds `lua_loads` too.
    lua: boolean
    --- Whether, declaring `lua`, it runs a file `--standalone` too
    --- ([`cosmic.test`]'s `standalone`): its closure holds
    --- `standalone_loads` as well.
    standalone: boolean
    --- Whether its worker is left unheld by Landlock, so a process it
    --- starts may have a root of its own ([`cosmic.test`]'s `nests`).
    nests: boolean
    store: boolean
    --- Whether its worker is given the system's own paths
    --- ([`confine.worker_unveil`]), and its key the host's packages
    --- and system ([`declared_key.system_identity`]).
    system: boolean
    --- The host caches declared, by name ([`build.caches`]), and where
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

  lua_loads: {string}
  standalone_loads: {string}
  loaded_beside: {string:{string}}
  compiler_sought: function(closure: {string}, lua: boolean): {string}
end

--- The variables every test may read undeclared, which a sandboxed
--- worker is given pinned: what the checker and the fuzzer read, how a
--- test of the sandbox itself confines what it starts (COSMIC_SANDBOX,
--- [`confine.must_confine`]), and what a process of the program
--- running the tests reads to run at all
--- ([`this_program.runtime_environment`]).
local pinned_env: {string} = { "TL_DEBUG", "TL_DEBUG_FACTS", "FUZZ_SEED", "FUZZ_ITERS", "FUZZ_CASE",
  "COSMIC_SANDBOX" }
for _, name in ipairs(this_program.runtime_environment) do pinned_env[#pinned_env + 1] = name end

--- The modules of the tree a process of this program runs before the
--- chunk `cosmic -e` hands it runs ([`build.dispatch`]'s `evaluate`),
--- and nothing else of the tree: cosmic's main and the lean way dispatch
--- takes to `-e`, with what each requires at its top level. A module
--- that declares `lua` ([`cosmic.test`]) holds them in its closure, as
--- if it required each at its top level, though not what each requires
--- only inside a function it does not call on that way -- dispatch
--- requires every verb's modules so -- so its key holds each by what it
--- is, and every process its tests start is held to that closure
--- (core/store.c's `hold_children`). A module added to that way is
--- refused to such a process, naming `lua`, until it is added here;
--- build/lua_children_test.tl holds a `-e` child to loading no more.
test_inputs.lua_loads = {
  "build.dispatch", "build.exit_status", "build.help_source", "build.verdict",
  "cmd.cosmic.main", "cosmic.env", "cosmic.fs", "cosmic.log",
}

--- What `cosmic --standalone` loads beyond `lua_loads` before the file
--- it checks and runs does ([`build.standalone`]): the checker it types
--- the file with ([`build.teal`], which loads the compiler beside it:
--- `loaded_beside`), with what each requires at its top level. A module
--- that declares `standalone` beside `lua` ([`cosmic.test`]) holds them
--- in its closure as it holds `lua_loads`; one that declares `lua` alone
--- does not, so an edit to the checker runs its tests no more, and a
--- child of it that runs a file standalone is refused, naming
--- `standalone`. build/lua_standalone_test.tl holds a standalone child
--- to loading no more. A standalone file that requires a module of the
--- standard library is typed from its declaration too, which the test
--- module holds by requiring that module at its top level.
test_inputs.standalone_loads = {
  "build.ast", "build.ast.match", "build.ast.match_cast", "build.ast.node",
  "build.ast.requires", "build.ast.rewrite", "build.ast.walk", "build.standalone",
  "build.teal", "cosmic.codec", "cosmic.hash", "cosmic.sqlite", "cosmic.store",
}

--- The names of `closure`, the import closure of a module that declares
--- `lua` as `lua` says, among which a reader of the compiler's identity
--- is sought ([`build.key_parts`]' `reads_compiler`), for its key and
--- for the `meta` rows its worker, and every process its tests start,
--- may read: every one of them but `lua_loads` and `standalone_loads`
--- where it declares `lua`. Neither way reads it before its chunk or
--- file runs, and [`build.dispatch`], which does, does so only past
--- requiring build.importer, a reader itself: so a closure that lets a
--- process reach that read holds a reader the search finds anyway, and
--- an edit to the compiler, which moves its identity, runs a test that
--- only runs Lua in a child no more than one that runs none.
function test_inputs.compiler_sought(closure: {string}, lua: boolean): {string}
  if not lua then return closure end
  local added: {string:boolean} = {}
  for _, list in ipairs({ test_inputs.lua_loads, test_inputs.standalone_loads }) do
    for _, name in ipairs(list) do added[name] = true end
  end
  local out: {string} = {}
  for _, name in ipairs(closure) do
    if not added[name] then out[#out + 1] = name end
  end
  return out
end

--- Modules a module loads by other means than `require`, by that
--- module: build.teal loads the compiler as bytecode
--- (`Store.bytecode("vendor.tl")`), which no parse follows. A closure
--- store carries each beside the module that loads it
--- ([`build.closure_store`]'s `loaded_beside`, which
--- build/lua_standalone_test.tl holds to this), and a process a `lua`
--- module's tests start may load it where the closure holds that module
--- ([`build.test_worker`]'s `hold_children`).
test_inputs.loaded_beside = { ["build.teal"] = { "vendor.tl" } }

--- Where [`build.fuzz`] keeps the corpus of every property.
local corpora <const> = "testdata/fuzz/"

--- Every module `m` requires, directly or not, and itself, that `by_path`
--- holds -- a module the binary carries rather than the tree is no file
--- of it -- as the files they are read from, sorted; and the declaration
--- file of each it requires that only `declarations`, the tree's
--- declaration files by import path, answers for. Whether [`build.fuzz`]
--- is among them rides along, and so do the modules' names, sorted.
---
--- `requires` holds only the literal names handed to `require` itself,
--- so a `require` of a computed name -- or, until [`build.ast.requires`]
--- follows it (the TODO in build/embed.tl), of a literal one through
--- `pcall(require, ...)` -- is not followed: the worker refuses one
--- that names a module of the tree outside this closure
--- ([`build.test_worker`]), so the miss fails the test rather than
--- leaving its key short.
---
--- The compiler -- `vendor.tl`, derived from vendor/tl/ and its
--- patches -- is no file of it, though build.teal loads it as bytecode
--- (`Store.bytecode("vendor.tl")`) rather than by `require`, so no
--- parse follows it: a key over the closure holds it apart, by its
--- bytecode, in the bytes of the closure store that carries it beside
--- build.teal ([`build.closure_store`]'s `loaded_beside`), as it holds every
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
  -- Each of `lua_loads`, for a module that declares `lua`, and of
  -- `standalone_loads`, for one that declares `standalone` beside it, as
  -- a module it requires whose own requires it does not follow: each
  -- one's top-level requires are among them.
  local declared: analyzer.Declared = m.inputs
  local function hold(loads: {string})
    for _, name in ipairs(loads) do
      local other = by_path[name]
      if other ~= nil and not seen[name] then
        seen[name] = true
        files[#files + 1] = other.file
        names[#names + 1] = name
      end
    end
  end
  if declared ~= nil and declared.lua then
    hold(test_inputs.lua_loads)
    if declared.standalone then hold(test_inputs.standalone_loads) end
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
--- `$NAME/path` (see [`cosmic.test`]), whose rest follows it at `#name +
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
    tool = false, lua = false, standalone = false, nests = false, store = false,
    system = false, caches = {},
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
    out.tool, out.store = declared.tool, declared.store
    out.lua = declared.lua == true
    out.standalone = declared.standalone == true
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
--- /proc, which [`cosmic.test`]'s `host` never names.
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
  if declared.tool then lines[#lines + 1] = "tool true" end
  if declared.lua then lines[#lines + 1] = "lua true" end
  if declared.standalone then lines[#lines + 1] = "standalone true" end
  if declared.nests then lines[#lines + 1] = "nests true" end
  if declared.store then lines[#lines + 1] = "store true" end
  if declared.system then lines[#lines + 1] = "system true" end
  list("caches", declared.caches or {})
  return table.concat(lines, "\n")
end

--- What a `needs` call was handed, as the build reads a declaration
--- ([`build.analyzer`]), for `canonical`: nil for none.
function test_inputs.as_declared(needs: inputs.Needs | nil): analyzer.Declared | nil
  if needs == nil then return nil end
  return { line = 0, reads = needs.reads or {}, host = needs.host or {},
    env = needs.env or {}, network = needs.network or {},
    tool = needs.tool == true, lua = needs.lua == true,
    standalone = needs.standalone == true, nests = needs.nests == true,
    store = needs.store == true, system = needs.system == true,
    caches = needs.caches or {} }
end

return test_inputs
