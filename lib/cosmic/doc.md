# doc

 Extract documentation from Teal files and render as markdown.
 Parses doc comments, records, functions, and examples from .tl files.

## Types

### DocIndex

 A documentation index containing all modules.

```teal
local record DocIndex
  modules: {string: ModuleDoc}
end
```

### DocModule

```teal
local record DocModule
  parse: function(source: string, file_path: string): ModuleDoc
  parse_dtl: function(source: string, file_path: string): ModuleDoc
  parse_file: function(file_path: string): ModuleDoc, string
  render: function(doc: ModuleDoc): string
  render_file: function(file_path: string): boolean, string
  serialize: function(doc: ModuleDoc): string
  serialize_index: function(index: DocIndex): string
  load_index: function(source: string): DocIndex, string
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
function parse_file(file_path: string): ModuleDoc, string
```

 Parse a file and return structured documentation.

### render_file

```teal
function render_file(file_path: string): boolean, string
```

 Main entry point: parse file and render markdown.

### serialize

```teal
function serialize(doc: ModuleDoc): string
```

 Serialize a ModuleDoc to Lua source code.

### serialize_index

```teal
function serialize_index(index: DocIndex): string
```

### load_index

```teal
function load_index(source: string): DocIndex, string
```
