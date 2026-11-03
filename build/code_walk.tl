--- Which modules the identities of the code that reads and checks name, and how each one's text is digested.
---
--- Three identities hold the text of the code that decides what a compile or a parse stores: the checker's readers
--- ([`build.pipeline`]'s `coded`), the analyzer ([`build.importer`]'s `analyzer_identity`) and the readers of the
--- record-field uses (`receivers_identity`). Each is a walk from roots over `require`, and its value ([`value`]) is a
--- hash of each module's name and the digest of its source. A test's pure store ([`build.closure_store`]) withholds
--- every module's text, so the writer of the store computes that value of the whole projection and keeps it in the
--- store's `meta` ([`held`]) for each walk whose roots the test's closure holds, which the identity then reads in
--- place of the text. This module holds the roots, the rules and the formula of the walks, which the identities and the
--- store's writer both use, so that what the store keeps is what the identity would have named.
---
--- TODO: key these identities on the code they run and not on its text, so that a comment in a module of a walk moves
--- no key (the pure store would then keep a digest of the module's tokens, not its source hash), once the token digest
--- of a module exists.
local Hash = require("cosmic.hash")
local Store = require("cosmic.store")

local record Walks
  --- The walk of the checker's readers, from [`build.pipeline`].
  pipeline: string
  --- The walk of the analyzer ([`build.importer`]'s `analyzer_modules`).
  analyzer: string
  --- The walk of the readers of the record-field uses.
  receivers: string

  --- The modules the analyzer walks from: the derivation and the extractors, generators and parser it calls. Each is a
  --- root of the compiler's identity too ([`build.identity`]'s `compiler_roots`), so a parse made again is a compile
  --- made again. The schema of the rows a parse stores ([`build.analysis_schema`]) is among them: what a source parses
  --- to is recorded in its columns.
  analyzer_roots: {string}

  --- The modules whose text the receivers' identity holds, in the order it holds them.
  receivers_modules: {string}

  --- What [`build.pipeline`] requires for a type alone (`local type`), which `requires` records though none of it runs
  --- there, and why the walk of the checker's readers leaves it out, by name. Only [`build.pipeline`]'s own require is
  --- left out: one that another module of the walk requires is in it. Every key `coded` names but a parse's holds each
  --- of these through the compiler's identity ([`build.identity`]'s `compiler_roots`), and a parse's holds the
  --- analyzer's modules ([`analyzer_roots`]).
  type_only: {string:string}

  --- The modules the walk `which` ([`pipeline`], [`analyzer`] or [`receivers`]) reaches over `requires`, sorted: a
  --- module of the walk of the checker's readers is one of `lang.` or `build.` only. Nil and why where `requires`
  --- failed.
  reach: function(which: string, requires: function(string): {string}?, string): {string}?, string

  --- The modules that start the walk `which`: the identity is named only where one of them is in the store.
  roots_of: function(which: string): {string}

  --- The name of the walk `which`'s identity over `requires` and the `digest` of each module's text (nil for a module
  --- held by no one): the hash of each module the walk reaches by its name and digest, in the order of the names. A module
  --- with no digest is left out of the walks of the checker's readers and of the analyzer, as an absent module is; the
  --- walk of the receivers' readers names none, for it needs both. Nil and why where `requires` failed, nil and "" for
  --- that.
  value: function(which: string, requires: function(string): {string}?, string,
                  digest: function(string): string?): string?, string

  --- What the running binary holds of the walk `which`'s value ([`value`]) in its `meta`: the pure store of a test whose
  --- closure holds the walk's roots ([`build.closure_store`]) keeps it, for it withholds the text it is made of. Nil in
  --- every other binary, whose identity is made of the modules it carries.
  held: function(which: string): string?

  --- The key the value of the walk `which` is kept under in a pure store's `meta`.
  meta_key: function(which: string): string
end

local pipeline <const> = "pipeline"
local analyzer <const> = "analyzer"
local receivers <const> = "receivers"

local analyzer_roots <const>: {string} = {
  "build.derivation", "build.analysis_schema", "build.bind",
  "build.doctest", "build.gen_syscalls", "build.link_text",
}

local receivers_modules <const>: {string} = { "build.syntax_receivers", "build.syntax_contracts" }

local type_only <const>: {string:string} = {
  ["build.plans"] = "the `Module` and `Generated` types of what a compile plans and keeps; build.importer runs the plan",
  ["build.derivation"] = "the types of what a parse is handed and tallies (`Fresh`, `Parses`, `Source`); it runs the " ..
    "parse, and is a root of the analyzer's identity",
}

local function roots_of(which: string): {string}
  if which == pipeline then return { "build.pipeline" } end
  if which == analyzer then return analyzer_roots end
  return receivers_modules
end

local function reach(which: string, requires: function(string): {string}?, string): {string}?, string
  local reached: mut {string:boolean} = {}
  local stack: mut {string} = {}
  for _, name in ipairs(roots_of(which)) do stack[#stack + 1] = name end
  if which == receivers then
    table.sort(stack)
    return stack, ""
  end
  local names: mut {string} = {}
  while #stack > 0 do
    local name = assert(table.remove(stack))
    if reached[name] ~= true then
      reached[name] = true
      local of_checker = name:sub(1, 5) == "lang." or name:sub(1, 6) == "build."
      if which ~= pipeline or of_checker then
        names[#names + 1] = name
        local required, trouble = requires(name)
        if required == nil then return nil, trouble end
        for _, next_name in ipairs(required) do
          if which ~= pipeline or name ~= "build.pipeline" or type_only[next_name] == nil then
            stack[#stack + 1] = next_name
          end
        end
      end
    end
  end
  table.sort(names)
  return names, ""
end

local function value(which: string, requires: function(string): {string}?, string,
                     digest: function(string): string?): string?, string
  local names, trouble = reach(which, requires)
  if names == nil then return nil, trouble end
  local parts: mut {string} = {}
  for _, name in ipairs(names) do
    local named = digest(name)
    if named ~= nil then
      parts[#parts + 1] = name .. "\n" .. named
    elseif which == receivers then
      return nil, ""
    end
  end
  return Hash.hex_sha256(table.concat(parts, "\n\0\n")), ""
end

--- The key the value of the walk `which` is kept under in a pure store's `meta`.
local function meta_key(which: string): string
  return "code_walk:" .. which
end

local function held(which: string): string?
  return Store.meta(meta_key(which))
end

local CodeWalk: Walks = {
  pipeline = pipeline, analyzer = analyzer, receivers = receivers, analyzer_roots = analyzer_roots,
  receivers_modules = receivers_modules, type_only = type_only, reach = reach, roots_of = roots_of, value = value,
  held = held, meta_key = meta_key,
}

return CodeWalk
