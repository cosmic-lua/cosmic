# doc

 Query the documentation index embedded in the binary.
 The `--docs` CLI's engine, and the shared doc-type vocabulary both
 halves of the doc family type themselves with. The extraction half
 — parsing Teal source, rendering markdown — lives in `_tool.doc`:
 only the toolchain parses source, so this public module is the
 query half.

## Types

### DocModule

```teal
local record DocModule
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
  is_public: function(name: string): boolean
  public_of: function(names: {string}): {string}
end
```
