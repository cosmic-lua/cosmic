--- Query the documentation index embedded in the binary: the `--docs`
--- CLI's engine, and the shared doc-type vocabulary both halves of the
--- doc family type themselves with (#992: the extraction half — parse
--- Teal source, render markdown — is `_tool.doc` now; only the
--- toolchain parses source, so the public module is the query half).
local types = require("cosmic.doc.types")

-- The query half of the converged `doc`/`docs` family: lookup and
-- search over the index embedded in the binary, behind the `--docs`
-- CLI. The type vocabulary (DocIndex, DocsResult, ...) is declared on
-- the module record below, where it is also the re-export surface.
local query = require("cosmic.doc.query")

local record DocModule
  --- The shared doc-type vocabulary, re-exported for the toolchain's
  --- extraction half (`_tool.doc`), which may not require the
  --- cosmic.doc.types shard directly (D19).
  type ModuleDoc = types.ModuleDoc
  type FunctionDoc = types.FunctionDoc
  type RecordDoc = types.RecordDoc
  type ExampleDoc = types.ExampleDoc
  type ExampleEntry = types.ExampleEntry
  type Param = types.Param
  type Return = types.Return
  type DocIndex = types.DocIndex
  type SearchResult = types.SearchResult

  -- Query: the index embedded in the binary (`--docs`). The fallible
  -- lookups return `string | nil, string` (#1001: DocsResult{ok, output}
  -- was the success-text-or-error-text-by-flag anti-pattern this very
  -- file documents render_file shedding).
  query: function(q?: string): string | nil, string
  is_available: function(): boolean
  topics: function(include_cosmo?: boolean): {{string, string}}
  embedded_index: function(): DocIndex | nil, string
  render_module: function(name: string, doc: ModuleDoc): string
  search: function(query: string, include_cosmo?: boolean): {SearchResult}
  render_search_results: function(results: {SearchResult}, query: string): string
  module_examples: function(query: string): string | nil, string
  guide: function(topic: string): string | nil, string
  guide_topics: function(): {string}
  guides: function(): {{string, string}}
  strip_frontmatter: function(content: string): string
end

local M: DocModule = {
  query = query.run,
  is_available = query.is_available,
  topics = query.topics,
  embedded_index = query.embedded_index,
  render_module = query.render_module,
  search = query.search,
  render_search_results = query.render_search_results,
  module_examples = query.module_examples,
  guide = query.guide,
  guide_topics = query.guide_topics,
  guides = query.guides,
  strip_frontmatter = query.strip_frontmatter,
}

return M
