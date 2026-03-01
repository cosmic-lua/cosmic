# doc_render

 Rendering and .d.tl parsing for the doc module.
 Contains the markdown renderer and the type declaration file parser.

## Types

### DocRenderModule

```teal
local record DocRenderModule
  render: function(doc: ModuleDoc): string
  parse_dtl: function(source: string, file_path: string): ModuleDoc
end
```

## Functions

### render

```teal
function render(doc: ModuleDoc): string
```

 Render documentation as markdown.

### parse_dtl

```teal
function parse_dtl(source: string, file_path: string): ModuleDoc
```

 Parse a .d.tl type declaration file and extract documentation.
