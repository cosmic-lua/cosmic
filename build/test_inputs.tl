--- What a test may read: its effective inputs, the default ones its
--- module's place in the tree gives it and the ones its module declares
--- ([`build.inputs`]).
---
--- A test's default inputs are
---
--- - its module's import closure, as source files: its own file and
---   the file of every module it requires, directly or not, by value
---   (a `local type` require of a module is no edge: see `closure`), as
---   the build's module graph has them, or the declaration file of one
---   only a declaration answers for;
--- - every fuzz corpus (`testdata/fuzz/`, where [`build.fuzz`] looks),
---   when the closure holds [`build.fuzz`]; and
--- - a pinned environment, `pinned_env`: what the checker and the
---   fuzzer read of it, and what a process of this program needs.
---
--- Its module declares the rest in a [`cosmic.test`] `policy`, which the
--- harness reads as paths of the tree (`reads`), of the host (`host`),
--- environment variables (`env`), the network (`network`), the tool itself
--- (`tool`), a root of its own for what it starts (`nests`), the tree's
--- projection opened directly (`store`), and the system's own programs
--- and files (`system`).
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
    --- Absolute paths outside the tree, each a file or /proc.
    host: {string}
    --- Environment variables, pinned or declared, by name.
    env: {string:boolean}
    --- The loopback addresses the tests may reach, by address.
    network: {string:boolean}
    tool: boolean
    --- Whether it starts this program only to run Lua in it
    --- ([`cosmic.test`]'s `lua`): its closure holds `lua_loads` too.
    lua: boolean
    --- Whether its worker is left unheld by Landlock, so a process it
    --- starts may have a root of its own ([`cosmic.test`]'s `nests`).
    nests: boolean
    noexec: boolean
    --- Whether this run proved private noexec scratch usable by this
    --- worker's identity, and why not when requested but unavailable.
    noexec_ready: boolean
    noexec_trouble: string
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
    --- Once `resolve` has run: why a `host` path cannot be given, ""
    --- when every one can.
    unresolved: string
  end

  lua_loads: {string}
  standalone_loads: {string}
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
--- is, and every process its tests start runs a sealed database of that closure
--- ([`build.test`]'s `sealed_for`), which carries no other module of the
--- program. A module added to that way is not found by such a process
--- until it is added here; build/lua_children_test.tl holds a `-e` child
--- to loading no more.
-- TODO: hold cosmic.errors and its closure here too: the core
-- requires it for an uncaught error's guidance (core/main.c's
-- `ask_guidance`), which a child of a `lua` module cannot load and so
-- prints none, silently, where another prints the catalog's.
test_inputs.lua_loads = {
  "build.dispatch", "build.exit_status", "build.help_source", "build.verdict",
  "cmd.cosmic.main", "cosmic.env", "cosmic.fs", "cosmic.log",
}

--- What `cosmic --standalone` loads beyond `lua_loads` before the file
--- it checks and runs does ([`build.standalone`]): the checker it types
--- the file with ([`build.teal`], which loads the compiler beside it:
--- [`build.closure_store`]'s `loaded_beside`), with what each requires at its top level. A module
--- that declares `lua` ([`cosmic.test`]) and requires [`build.standalone`]
--- at its top level holds them in its closure, which that module's
--- requires reach; one that declares `lua` alone does not, so an edit to
--- the checker runs its tests no more, and a child of it that runs a
--- file standalone does not find the checker.
--- build/lua_standalone_test.tl holds a standalone child to loading no
--- more, and [`build.standalone`]'s closure to holding every one. A
--- standalone file that requires a module of the
--- standard library is typed from its declaration too, which the test
--- module holds by requiring that module at its top level.
test_inputs.standalone_loads = {
  "build.ast", "build.ast.match", "build.ast.match_cast", "build.ast.node",
  "build.ast.requires", "build.ast.rewrite", "build.ast.walk", "build.standalone",
  "build.teal", "cosmic.codec", "cosmic.hash", "cosmic.sqlite", "cosmic.store",
}

--- The names of `closure`, the import closure of a module that declares
--- `lua` as `lua` says, among which a reader of the compiler's identity
--- is sought ([`build.key_parts`]' `reads_compiler`), for its key: every
--- one of them but `lua_loads` and `standalone_loads` where it declares
--- `lua`. Neither way reads it before its chunk or
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

--- Where [`build.fuzz`] keeps the corpus of every property.
local corpora <const> = "testdata/fuzz/"

--- Every module `m` requires, directly or not, and itself, that `by_path`
--- holds -- a module the binary carries rather than the tree is no file
--- of it -- as the files they are read from, sorted; and the declaration
--- file of each it requires that only `declarations`, the tree's
--- declaration files by import path, answers for. Whether [`build.fuzz`]
--- is among them rides along, and so do the modules' names, sorted.
---
--- `type_only` names the edges not followed (importer path, then required
--- name): the `local type` requires of a module, which Teal erases, so
--- that nothing of what the required module is loads when the importer
--- runs ([`build.test`]'s `type_only_imports`). What the imported type
--- does at run time (an `is` against a record's `where`, an enum's
--- test) is compiled into the importer's bytecode, which the closure
--- holds. A test module's own requires are all followed, so
--- `local type _ = require("x")` in a test still brings `x` -- its
--- source and declarations, for a snippet the test type-checks -- into
--- its closure.
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
                       declarations: {string:string},
                       type_only?: {string:{string:boolean}}): {string}, boolean, {string}
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
      local erased = type_only ~= nil and type_only[here.path] or {}
      for _, name in ipairs(here.requires) do
        local other = by_path[name]
        if name == "build.fuzz" then fuzzes = true end
        if erased[name] then
          -- Loads nothing, so no part of the closure.
        elseif other ~= nil and not seen[name] then
          stack[#stack + 1] = other
        elseif other == nil and declarations[name] ~= nil and not seen[name] then
          seen[name] = true
          files[#files + 1] = declarations[name]
          names[#names + 1] = name
        end
      end
    end
  end
  -- Each of `lua_loads`, for a module that declares `lua`, as a module it
  -- requires whose own requires it does not follow: each one's top-level
  -- requires are among them.
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
                             declarations: {string:string},
                             type_only?: {string:{string:boolean}}): {string}
  local _, _, names = closure(m, by_path, declarations, type_only)
  return names
end

--- `m`'s default inputs and its declared ones together: `by_path` is
--- every module the build compiled, by path, and `declarations` every
--- declaration file of the tree (`<path>.d.tl`), by import path.
function test_inputs.effective(m: Module, by_path: {string:Module},
                               declarations: {string:string},
                               type_only?: {string:{string:boolean}}): test_inputs.Effective
  local out: test_inputs.Effective = {
    files = {}, reads = {}, host = {}, env = {}, network = {},
    tool = false, lua = false, nests = false, noexec = false, noexec_ready = false,
    noexec_trouble = "", store = false,
    system = false, caches = {},
    cache_paths = {}, unresolved = "",
  }
  local files, fuzzes = closure(m, by_path, declarations, type_only)
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
    out.tool, out.store = declared.tool, declared.store
    out.lua = declared.lua == true
    out.nests = declared.nests == true
    out.noexec = declared.noexec == true
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
  -- Not String.starts_with: every worker loads this module, and
  -- [`worker.judge`] fails a test whose worker ran a module in neither its
  -- closure nor [`worker.loads`]. Naming cosmic.string there would move what
  -- every worker loads, a harness change that needs an `epoch` bump.
  return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"
end

--- The path a `host` path `declared` by a module resolves to, or nil and
--- why it cannot be given. `roots` are where the tree is (its path and
--- where that resolves). A path cannot be given when it is the tree,
--- beneath it or above it.
function test_inputs.resolved(declared: string, roots: {string}): string | nil, string
  local path = declared
  local said = string.format("Test.policy grant of the host path %q", declared)
  local real = confine.resolution(path)
  for _, root in ipairs(roots) do
    for _, where in ipairs({ path, real }) do
      if where ~= "" and root ~= "" and beneath(where, root) then
        return nil, string.format("%s: %s is the tree's; a path of the tree is a grant " ..
            "without a leading \"/\"", said, path)
      elseif where ~= "" and root ~= "" and beneath(root, where) then
        return nil, string.format("%s: %s holds the tree; grant the paths beneath it " ..
            "the tests read", said, path)
      end
    end
  end
  return path, ""
end

--- Resolves each `host` path of `effective` (`resolved`), and leaves in
--- `unresolved` why one cannot be given: see `resolved`, whose `roots`
--- this takes, or it is a directory, but for /proc, which
--- [`cosmic.test`]'s host grants never name.
function test_inputs.resolve(effective: test_inputs.Effective, roots: {string})
  local host: {string} = {}
  effective.unresolved = ""
  for _, declared in ipairs(effective.host) do
    local path, trouble = test_inputs.resolved(declared, roots)
    -- A file, or /proc: a directory no key holds by what it holds (R3).
    -- One not there is none, as a file of another platform's is not.
    local st: sys.Stat = nil
    if path ~= nil then
      local found, _ = sys.stat(path)
      st = found
    end
    if st ~= nil and st.kind == "dir" and not beneath(path, "/proc") then
      path, trouble = nil, string.format("Test.policy grant of the host path %q: %s is a " ..
          "directory; a grant of the host names files, or /proc: grant the files the tests read",
        declared, path)
    end
    if path == nil then
      if effective.unresolved == "" then effective.unresolved = trouble end
    else
      host[#host + 1] = path
    end
  end
  effective.host = host
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
  if declared.nests then lines[#lines + 1] = "nests true" end
  if declared.noexec then lines[#lines + 1] = "noexec true" end
  if declared.store then lines[#lines + 1] = "store true" end
  if declared.system then lines[#lines + 1] = "system true" end
  list("caches", declared.caches or {})
  list("requires", declared.requires or {})
  return table.concat(lines, "\n")
end

--- What a `policy` stands for, as the build reads a declaration
--- ([`build.analyzer`]), for `canonical`: nil for none.
function test_inputs.as_declared(needs: inputs.Needs | nil): analyzer.Declared | nil
  if needs == nil then return nil end
  return { line = 0, reads = needs.reads or {}, host = needs.host or {},
    env = needs.env or {}, network = needs.network or {},
    tool = needs.tool == true, lua = needs.lua == true,
    nests = needs.nests == true,
    noexec = needs.noexec == true,
    store = needs.store == true, system = needs.system == true,
    caches = needs.caches or {}, requires = needs.requires or {} }
end

return test_inputs
