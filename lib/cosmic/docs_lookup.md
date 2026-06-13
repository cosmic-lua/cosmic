# docs_lookup

 Symbol lookup and suggestion helpers for the docs module.
 Locates symbols across modules and builds not-found error messages.

## Types

### DocsLookupModule

```teal
local record DocsLookupModule
  find_symbol_locations: function(symbol: string, index: DocIndex): {string}
  list_symbols: function(doc: ModuleDoc): {string}
  symbol_not_found: function(symbol: string, matched_mod: string, index: DocIndex): string
end
```

## Functions

### find_symbol_locations

```teal
function find_symbol_locations(symbol: string, index: DocIndex): {string}
```

 Find where a symbol lives across all modules (for "did you mean" suggestions).

**Parameters:**

- `symbol` (string) - The symbol name to locate
- `index` (DocIndex) - The documentation index

**Returns:**

- {string} - Qualified locations (module.symbol) where the name exists

### list_symbols

```teal
function list_symbols(doc: ModuleDoc): {string}
```

 List a module's addressable symbols (functions, records, record methods).

**Parameters:**

- `doc` (ModuleDoc) - The module documentation

**Returns:**

- {string} - Symbol names, deduplicated, in definition order

### symbol_not_found

```teal
function symbol_not_found(symbol: string, matched_mod: string, index: DocIndex): string
```

 Build the error message for a symbol that was not found in a module.
 Suggests other locations for the name, or lists the module's available
 symbols so the caller does not need a second lookup.

**Parameters:**

- `symbol` (string) - The symbol that was not found
- `matched_mod` (string) - The module that was searched
- `index` (DocIndex) - The documentation index

**Returns:**

- string - Multi-line error message
