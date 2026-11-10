--- Which modules the identities of the code that reads and checks hash the source of.
---
--- Four identities hold the source of the code that decides what a compile or a parse stores: the checker's readers
--- ([`build.pipeline`]'s `coded`), the analyzer ([`build.importer`]'s `analyzer_identity`), the readers of the
--- record-field uses (`receivers_identity`) and the code that finds the links of the files ([`build.work`]'s
--- `links_finder`). Each is a walk from roots over `require`, defined here once, so that the identities and the writer
--- of a test's pure store ([`build.closure_store`]) reach the same modules: the pure store keeps the source of exactly the
--- walks a test's closure declares it reads (it requires [`build.reads.pipeline`], `analyzer`, `receivers` or `links`).

-- TODO: hash the tokens of each module of a walk, not its source, in the four identities (build.pipeline's `identity`,
-- build.importer's `analyzer_named` and `receivers_identity`, build.work's `links_finder`) once a comment-insensitive
-- fingerprint of a module exists, so that a comment in a module of a walk moves no key; the pure store would then keep
-- that fingerprint in place of the source.

local record Walks
  --- The walk of the checker's readers, from [`build.pipeline`].
  pipeline: string
  --- The walk of the analyzer ([`build.importer`]'s `analyzer_modules`).
  analyzer: string
  --- The walk of the readers of the record-field uses.
  receivers: string
  --- The walk of the code that finds the links of the files ([`build.work`]'s `links_finder`).
  links: string
  --- Every walk, in a fixed order.
  walks: {string}

  --- The modules the analyzer walks from: the derivation, the parse ([`build.parse_derive`], which reads a source and
  --- writes its rows) and the extractors, generators and parser they call. Each but the parse is a root of the compiler's identity too
  --- ([`build.identity`]'s `compiler_roots`), and the parse is in the walk of the checker's readers ([`pipeline`]), which
  --- [`build.pipeline`] requires it into and every compile's key holds, so a parse made again is a compile made again. The schema of the rows a
  --- parse stores ([`build.analysis_schema`]) is among them: what a source parses to is recorded in its columns. The
  --- walk reaches no module of the checker ([`lang.check`] and what only it runs), which a parse does not run: a root
  --- or a module it reaches that came to require one, for a type alone even, would parse the tree again on every edit
  --- to the checker, and build/importer_test.tl holds the walk to none.
  analyzer_roots: {string}

  --- The modules a module declares what text it reads by requiring (a value `require`, which the closure of a test follows),
  --- each with the word it declares ([`build.reads.all`] and its siblings): `pipeline`, `analyzer`, `receivers` and `links` for the walks of this
  --- module, whose sources a pure store keeps; `stubs` for the stubs of the standard-library modules a test names
  --- ([`build.standard_text`]); `declarations` for a reader of the declarations alone, which every store keeps; and `all`
  --- for a reader of any text, which gives a test the full store.
  markers: {string:string}

  --- The modules whose text the receivers' identity holds, in the order it holds them.
  receivers_modules: {string}

  --- What [`build.pipeline`] requires for a type alone (`local type`), which `requires` records though none of it runs
  --- there, and why the walk of the checker's readers leaves it out, by name. Only [`build.pipeline`]'s own require is
  --- left out: one that another module of the walk requires is in it. Every key `coded` names holds each of these
  --- through the compiler's identity ([`build.identity`]'s `compiler_roots`); a parse is keyed by the analyzer's modules
  --- ([`analyzer_roots`]) and not by `coded`.
  type_only: {string:string}

  --- The modules the walk `which` ([`pipeline`], [`analyzer`], [`receivers`] or [`links`]) reaches over `requires`,
  --- sorted: a module of the walk of the checker's readers is one of `lang.` or `build.` only, and the walk of the
  --- receivers' readers is its two modules, followed no further. Nil and why where `requires` failed.
  reach: function(which: string, requires: function(string): {string}?, string): {string}?, string

  --- The modules that start the walk `which`: the identity is named only where one of them is in the store.
  roots_of: function(which: string): {string}
end

local pipeline <const> = "pipeline"
local analyzer <const> = "analyzer"
local receivers <const> = "receivers"
local links <const> = "links"
local walks <const>: {string} = { pipeline, analyzer, receivers, links }

local analyzer_roots <const>: {string} = {
  "build.derivation", "build.analysis_schema", "build.bind",
  "build.doctest", "build.gen_syscalls", "build.link_text", "build.parse_derive",
}

local receivers_modules <const>: {string} = { "build.syntax_receivers", "build.syntax_contracts" }

local type_only <const>: {string:string} = {
  ["build.plans"] = "the `Module` and `Generated` types of what a compile plans and keeps; build.importer runs the plan",
}

local markers <const>: {string:string} = {
  ["build.reads.pipeline"] = pipeline, ["build.reads.analyzer"] = analyzer, ["build.reads.receivers"] = receivers, ["build.reads.links"] = links,
  ["build.reads.all"] = "all",
}

local function roots_of(which: string): {string}
  if which == pipeline then return { "build.pipeline" } end
  if which == analyzer then return analyzer_roots end
  if which == links then return { "build.link_files" } end
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

local CodeWalk: Walks = {
  pipeline = pipeline, analyzer = analyzer, receivers = receivers, links = links, walks = walks, analyzer_roots = analyzer_roots,
  receivers_modules = receivers_modules, markers = markers, type_only = type_only, reach = reach, roots_of = roots_of,
}

return CodeWalk
