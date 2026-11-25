--- The checks of the tree over what modules declare: every quieted method one a module declares, every member kept
--- to a few files used by those alone, and every declaration's requires declared.

local closure_store = require("build.closure_store")
local ContractRules = require("build.contract_rules")
local _ = require("build.reads.all")
local type build_schema = require("build.schema")
local type Build = build_schema.Build

local record tree_declares
end

--- Each of `names` (by default [`build.contract_rules`]' `quiet_entries`), as
--- `<module> <symbol>`, that no module of `db` declares.
function tree_declares.quieted(db: Build, names?: {string}): {string}
  local out: mut {string} = {}
  for _, name in ipairs(names or ContractRules.quieted_names()) do
    local module, symbol = name:match("^(%S+) (%S+)$")
    local rows, trouble = db:rows(
      "SELECT 1 FROM docs WHERE module = ?1 AND symbol = ?2 LIMIT 1",
      { { text = module or "" }, { text = symbol or "" } })
    if rows == nil then
      return { "reading the docs: " .. tostring(trouble) }
    end
    if #rows == 0 then
      out[#out + 1] = name .. " is quieted in build/contract_rules.tl, but no module " ..
        "declares it -- remove it"
    end
  end
  return out
end

--- A member only some files may refer to.
local record Restriction
  --- The files, by path, that may use it.
  files: {string}
  --- What a file outside them does instead.
  why: string
end

--- The members the tree keeps to a few files, by `<module> <member>`: a
--- test that asks whether this platform has a sandbox, in place of
--- declaring `requires` or ending itself with [`Test.skip`], would branch
--- on what it was written to hold the platform to, and pass having checked
--- nothing where the branch goes the other way.
local restricted: {string: Restriction} = {
  ["cosmic.test passed_unchecked"] = {
    files = { "build/fuzz/init.tl" },
    why = "only the fuzz runner may say a pass did not check on purpose: a test that " ..
      "cannot check what it is about skips or declares `requires`, and one that checks " ..
      "asserts",
  },
  ["build.confine sandbox_platform"] = {
    files = { "build/confine.tl", "build/host_requires.tl",
      "build/test_sandbox_probe.tl" },
    why = "only the probe of what the host has asks it: a test declares `requires` " ..
      "(build/host_names.tl) or, where no name stands for what it needs, ends itself " ..
      "with `Test.skip(reason)`",
  },
}

--- Each use in `db` of a member of `rules` (by default [`restricted`])
--- from a file its rule does not name, as `<file>:<line>: <module> <member>
--- ...`; by default also each module that requires one only a few may
--- ([`tree_declares.requirers`]).
function tree_declares.restricted(db: Build, rules?: {string: Restriction}): {string}
  local out: mut {string} = {}
  local names: mut {string} = {}
  for name in pairs(rules or restricted) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local rule = assert((rules or restricted)[name], "a name listed is one of the rules")
    local module, symbol = name:match("^(%S+) (%S+)$")
    local rows, trouble = db:rows(
      "SELECT from_file, line FROM uses WHERE module = ?1 AND symbol = ?2 " ..
        "ORDER BY from_file, line",
      { { text = module or "" }, { text = symbol or "" } })
    if rows == nil then
      return { "reading the uses: " .. tostring(trouble) }
    end
    local allowed_here: mut {string: boolean} = {}
    for _, file in ipairs(rule.files) do allowed_here[file] = true end
    for _, row in ipairs(rows) do
      if allowed_here[row:text(1)] ~= true then
        out[#out + 1] = row:text(1) .. ":" .. tostring(row:integer(2)) .. ": " .. name .. " is used outside " ..
          table.concat(rule.files, ", ") .. ": " .. rule.why
      end
    end
  end
  if rules == nil then
    for _, line in ipairs(tree_declares.requirers(db)) do out[#out + 1] = line end
  end
  return out
end

--- The modules only a few may require, by module: the loader of a module by a name got at run time is no edge of the
--- build, so a module that holds it can load what no key, closure or carried program holds. Who may require it, not who
--- calls it, is what is kept, so an alias of it in another module matters nothing.
local requirers: {string: Restriction} = {
  ["build.load_module"] = {
    files = { "build.dispatch", "build.test_worker", "build.load_module_test" },
    why = "only the tool's entry and the test worker load a module by a name they get at run " ..
      "time, which is no edge of the build: any other module requires what it needs by a " ..
      "literal name, `require(\"cosmic.fs\")`, or picks from a table of such requires",
  },
  ["cosmic.internal.compiled"] = {
    files = { "build.lua_tail", "build.sandbox", "build.standalone", "build.test_worker", "build.fact_hook_test",
      "core.class_form_test", "lang.check_programs", "lang.codegen_test" },
    why = "only the modules that load the Lua the compiler wrote read the class forms of patch/lua/, whose `@v` " ..
      "answers a metatable whatever `__metatable` says: any other module loads text with `load`, which refuses them",
  },
  ["cosmic.internal.globals"] = {
    files = { "build.fuzz", "build.load_module",
      "build.sandbox", "build.sealed_worker_test", "build.standalone",
      "build.test_closure_diagnostic_test", "build.test_closure_test", "build.test_worker_test", "build.type_watch", "core.load_env_test", "core.surface_test",
      "cosmic.coverage_test", "cosmic.flags_test", "test.coverage_cache_test" },
    why = "only the modules that run a program or a hook as a chunk of Lua text take the globals whole, as its " ..
      "environment: it holds `require`, which a chunk loads modules the build does not see by; any other module " ..
      "passes the chunk the few names it needs",
  },
}

--- Each module of `db` (by its `decl_imports`, which hold a core module's name too) that requires a module of `rules` (by default [`requirers`]) and is not one that rule names, as
--- `<module>: requires <name>, which only <modules> may require: <why>`.
function tree_declares.requirers(db: Build, rules?: {string: Restriction}): {string}
  local out: mut {string} = {}
  for name, rule in pairs(rules or requirers) do
    local rows, trouble = db:rows(
      "SELECT path FROM decl_imports WHERE requires = ?1 ORDER BY path", { { text = name } })
    if rows == nil then
      return { "reading the imports: " .. tostring(trouble) }
    end
    local allowed_here: mut {string: boolean} = {}
    for _, module in ipairs(rule.files) do allowed_here[module] = true end
    for _, row in ipairs(rows) do
      if allowed_here[row:text(1)] ~= true then
        out[#out + 1] = row:text(1) .. ": requires " .. name .. ", which only " .. table.concat(rule.files, ", ") ..
          " may require: " .. rule.why
      end
    end
  end
  table.sort(out)
  return out
end

--- Each declaration of `db` that requires a name no declaration of `db`
--- covers, as `<declaration> requires <name>`: a closure store
--- follows a declaration's requires among declarations alone
--- ([`build.closure_store`]'s `declared`), so a module one required would
--- be neither carried nor in the store's address.
function tree_declares.declarations(db: Build): {string}
  local rows, trouble = db:rows(
    "SELECT path, CAST(inflate(source) AS TEXT) FROM decls ORDER BY path")
  if rows == nil then
    return { "reading the declarations: " .. tostring(trouble) }
  end
  local declared: mut {string:boolean} = {}
  for _, row in ipairs(rows) do declared[row:text(1)] = true end
  local out: mut {string} = {}
  for _, row in ipairs(rows) do
    for _, name in ipairs(closure_store.required_by(row:text(2))) do
      if declared[name] ~= true then
        out[#out + 1] = row:text(1) .. " requires " .. name .. ", which is no declaration: " ..
          "a closure store follows a declaration's requires among declarations alone " ..
          "(build/closure_store.tl's `declared`), so declare what it needs of " .. name ..
          " in a declaration, or teach the store to follow a module"
      end
    end
  end
  return out
end

return tree_declares
