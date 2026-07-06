# docs

 Access embedded documentation — a `go doc`-style CLI over the binary.

## Types

### DocsModule

```teal
local record DocsModule
  run: function(query?: string): DocsResult
  has_docs: function(): boolean
  list_topics: function(include_cosmo?: boolean): {{string, string}}
  load_index: function(): DocIndex | nil, string
  render_module: function(name: string, doc: ModuleDoc): string
  search: function(query: string, include_cosmo?: boolean): {SearchResult}
  render_search_results: function(results: {SearchResult}, query: string): string
  show_module_examples: function(query: string): DocsResult
  show_guide: function(topic: string): DocsResult
  list_guide_topics: function(): {string}
  list_guides: function(): {{string, string}}
  strip_frontmatter: function(content: string): string
end
```

## Functions

### load_index

```teal
function load_index(): DocIndex | nil, string
```

 Load the embedded documentation index.

**Returns:**

- DocIndex - | nil The documentation index, or nil if not available
- string - Error message if loading failed

### has_docs

```teal
function has_docs(): boolean
```

 Check if embedded docs are available.

**Returns:**

- boolean - True if docs are embedded

### strip_frontmatter

```teal
function strip_frontmatter(content: string): string
```

 Strip YAML frontmatter from markdown content.

### list_guide_topics

```teal
function list_guide_topics(): {string}
```

 List available guide topics from the embedded skills directory.

### list_guides

```teal
function list_guides(): {{string, string}}
```

 List guides with descriptions from each file's heading.

### show_guide

```teal
function show_guide(topic: string): DocsResult
```

 Show a guide topic or list all guides.

### list_topics

```teal
function list_topics(include_cosmo?: boolean): {{string, string}}
```

 List all available documentation topics.

**Parameters:**

- `include_cosmo` (boolean) - Include low-level cosmo.* modules (default: false)

**Returns:**

- {{string, - string}} List of {name, description} pairs, sorted by name

### search

```teal
function search(query: string, include_cosmo?: boolean): {SearchResult}
```

 Search documentation for a query string.

**Parameters:**

- `query` (string) - The search query
- `include_cosmo` (boolean) - Include low-level cosmo.* modules (default: false)

**Returns:**

- {SearchResult} - List of search results, sorted by relevance

### show_module_examples

```teal
function show_module_examples(query: string): DocsResult
```

 Show examples for a specific module, optionally filtered by function name.

**Parameters:**

- `query` (string) - Module name (full, bare, or module.function)

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
