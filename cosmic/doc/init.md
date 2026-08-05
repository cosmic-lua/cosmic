# doc

 Extract documentation from Teal files and render as markdown.
 Parses doc comments, records, functions, and examples from .tl files.

## Types

### DocModule

```teal
local record DocModule
  parse: function(source: string, file_path: string): ModuleDoc
  parse_dtl: function(source: string, file_path: string): ModuleDoc
  parse_file: function(file_path: string): ModuleDoc | nil, string
  render: function(doc: ModuleDoc): string
  render_file: function(file_path: string): string | nil, string
  load_index: function(source: string): DocIndex | nil, string
  run: function(query?: string): DocsResult
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
```

## Functions

### parse

```teal
function parse(source: string, file_path: string): ModuleDoc
```

 Parse a .tl file and extract documentation.

**Parameters:**

- `source` (string) - The source code to parse
- `file_path` (string) - Path to the file being parsed

**Returns:**

- ModuleDoc - Complete documentation for the module

### parse_file

```teal
function parse_file(file_path: string): ModuleDoc | nil, string
```

 Parse a file and return structured documentation.

### render_file

```teal
function render_file(file_path: string): string | nil, string
```

 Main entry point: parse file and render markdown. A fallible VALUE
 (the markdown), not a fallible effect: the old boolean, string shape
 made slot 2 the payload on success and the error on failure, so
 every caller branched on which meaning it held.

### load_index

```teal
function load_index(source: string): DocIndex | nil, string
```
