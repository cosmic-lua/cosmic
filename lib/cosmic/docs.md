# docs

 Access embedded documentation from the cosmic binary.
 Provides a CLI interface similar to Go's `go doc` command.
 Documentation is parsed at build time and embedded as a serialized Lua index.

## Types

### Param

 A function parameter.

```teal
local record Param
  name: string
  param_type: string
  description: string
end
```

### Return

 A function return value.

```teal
local record Return
  return_type: string
  description: string
end
```

### FunctionDoc

 Documentation for a function.

```teal
local record FunctionDoc
  name: string
  description: string
  params: {Param}
  returns: {Return}
  signature: string
  line: integer
  is_local: boolean
end
```

### RecordDoc

 Documentation for a record type.

```teal
local record RecordDoc
  name: string
  description: string
  fields: {{string, string, string}}
  line: integer
end
```

### ExampleDoc

 Documentation for an example function.

```teal
local record ExampleDoc
  name: string
  description: string
  body: string
  expected_output: string
  line: integer
end
```

### ModuleDoc

 Complete documentation for a module.

```teal
local record ModuleDoc
  file: string
  module_doc: string
  functions: {FunctionDoc}
  records: {RecordDoc}
  examples: {ExampleDoc}
end
```

### DocIndex

 A documentation index containing all modules.

```teal
local record DocIndex
  modules: {string:ModuleDoc}
end
```

### DocsResult

 Result from a docs operation.

```teal
local record DocsResult
  ok: boolean
  output: string
end
```

### SearchResult

 Search result entry.

```teal
local record SearchResult
  module_name: string
  symbol_name: string
  symbol_type: string
  description: string
  match_score: integer
  --  Calculate match score for a search result.
  --  Scoring tiers (highest to lowest):
  match: 100 (module), 95 (function/record), 90 (method)
  --  Calculate match score for a search result.
  --  Scoring tiers (highest to lowest):
  --    1. Exact name match: 100 (module), 95 (function/record), 90 (method)
  match: 80 (module), 75 (function/record), 70 (method)
  --  Calculate match score for a search result.
  --  Scoring tiers (highest to lowest):
  --    1. Exact name match: 100 (module), 95 (function/record), 90 (method)
  --    2. Partial name match: 80 (module), 75 (function/record), 70 (method)
  query: +15 bonus for symbols
  --  Calculate match score for a search result.
  --  Scoring tiers (highest to lowest):
  --    1. Exact name match: 100 (module), 95 (function/record), 90 (method)
  --    2. Partial name match: 80 (module), 75 (function/record), 70 (method)
  --    3. Module path contains query: +15 bonus for symbols
  only: 30 (module), 25 (function/record), 20 (method/example)
  name_lower: string,
  desc: string,
  query_lower: string,
  base_exact: integer,
  base_partial: integer,
  base_desc: integer
  name_lower: find(query_lower, 1, true) then
  desc: lower():find(query_lower, 1, true) then
  --  Search documentation for a query string.
  --  By default, excludes low-level cosmo.* modules from results.
  default: false)
  --  Search documentation for a query string.
  --  By default, excludes low-level cosmo.* modules from results.
  query: string, include_cosmo?: boolean): {SearchResult}
end
```

### ExampleEntry

 Entry for examples list.

```teal
local record ExampleEntry
  module_name: string
  example_name: string
  description: string
end
```

### DocsModule

```teal
local record DocsModule
  run: function(query?: string): DocsResult
  has_docs: function(): boolean
  list_topics: function(include_cosmo?: boolean): {{string, string}}
  load_index: function(): DocIndex, string
  render_module: function(name: string, doc: ModuleDoc): string
  search: function(query: string, include_cosmo?: boolean): {SearchResult}
  render_search_results: function(results: {SearchResult}, query: string): string
  show_module_examples: function(module_name: string): DocsResult
end
```

## Functions

### load_index

```teal
function load_index(): DocIndex, string
```

 Load the embedded documentation index.

**Returns:**

- DocIndex - The documentation index, or nil if not available
- string - Error message if loading failed

### has_docs

```teal
function has_docs(): boolean
```

 Check if embedded docs are available.

**Returns:**

- boolean - True if docs are embedded

### list_topics

```teal
function list_topics(include_cosmo?: boolean): {{string, string}}
```

 List all available documentation topics.

**Parameters:**

- `include_cosmo` (boolean) - Include low-level cosmo.* modules (default: false)

**Returns:**

- {{string, - string}} List of {name, description} pairs, sorted by name

### render_module

```teal
function render_module(name: string, doc: ModuleDoc): string
```

 Render a full module as CLI output.

**Parameters:**

- `name` (string) - Module name
- `doc` (ModuleDoc) - Module documentation

**Returns:**

- string - Formatted output

### search

```teal
function search(query: string, include_cosmo?: boolean): {SearchResult}
```

 Search documentation for a query string.
 By default, excludes low-level cosmo.* modules from results.

**Parameters:**

- `query` (string) - The search query
- `include_cosmo` (boolean) - Include low-level cosmo.* modules (default: false)

**Returns:**

- {SearchResult} - List of search results, sorted by relevance

### render_search_results

```teal
function render_search_results(results: {SearchResult}, query: string): string
```

 Render search results as CLI output.

**Parameters:**

- `results` ({SearchResult}) - List of search results
- `query` (string) - The original search query

**Returns:**

- string - Formatted output

### show_module_examples

```teal
function show_module_examples(module_name: string): DocsResult
```

 Show examples for a specific module.

**Parameters:**

- `module_name` (string) - The module name (e.g., "cosmic.sqlite")

**Returns:**

- DocsResult - Result with examples content

### run

```teal
function run(query?: string): DocsResult
```

 Main entry point for the docs command.

**Parameters:**

- `query` (string) - Optional query string (module or module.symbol)

**Returns:**

- DocsResult - Result with documentation content
