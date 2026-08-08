--- Query the documentation index embedded in the binary: the `--docs`
--- CLI's engine, and the shared doc-type vocabulary both halves of the
--- doc family type themselves with (#992: the extraction half — parse
--- Teal source, render markdown — is `_tool.doc` now; only the
--- toolchain parses source, so the public module is the query half).
local types = require("cosmic.doc.types")

--- A documentation index containing all modules (the shared record from
--- cosmic.doc.types, so extraction and query agree on the type).
local type DocIndex = types.DocIndex

-- The query half of the module (`doc` and `docs` converged into one
-- family): lookup and search over the index embedded in the binary,
-- behind the `--docs` CLI.
local query = require("cosmic.doc.query")
local DocsResult = types.DocsResult
local SearchResult = types.SearchResult

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
  type DocsResult = types.DocsResult
  type SearchResult = types.SearchResult

  -- Query: the index embedded in the binary (`--docs`).
  query: function(q?: string): DocsResult
  has_docs: function(): boolean
  list_topics: function(include_cosmo?: boolean): {{string, string}}
  embedded_index: function(): DocIndex | nil, string
  render_module: function(name: string, doc: ModuleDoc): string
  search: function(query: string, include_cosmo?: boolean): {SearchResult}
  render_search_results: function(results: {SearchResult}, query: string): string
  show_module_examples: function(query: string): DocsResult
  show_guide: function(topic: string): DocsResult
  list_guide_topics: function(): {string}
  list_guides: function(): {{string, string}}
  strip_frontmatter: function(content: string): string
end

local M: DocModule = {
  query = query.run,
  has_docs = query.has_docs,
  list_topics = query.list_topics,
  embedded_index = query.embedded_index,
  render_module = query.render_module,
  search = query.search,
  render_search_results = query.render_search_results,
  show_module_examples = query.show_module_examples,
  show_guide = query.show_guide,
  list_guide_topics = query.list_guide_topics,
  list_guides = query.list_guides,
  strip_frontmatter = query.strip_frontmatter,
}

return M
