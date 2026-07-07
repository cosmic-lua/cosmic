# fetch_headers

 Response-header normalization for the cosmic.fetch module.
 cosmo.Fetch/FetchStream return headers with original-case names, and
 repeatable headers (Vary, Cache-Control, ...) arrive as nested array
 tables even though the binding declares {string: string}. This chunk
 flattens that into two honest views in one pass:
 - headers: lowercase names, repeated values joined ", " (RFC 9110 §5.3)
 - raw_headers: lowercase names, every value in arrival order

## Types

### FetchHeadersModule

```teal
local record FetchHeadersModule
  normalize: function(raw: {string: any}): {string: string}, {string: {string}}
end
```

## Functions

### normalize

```teal
function normalize(raw: {string: any}): {string: string}, {string: {string}}
```

 Normalize a raw header table from cosmo.Fetch/FetchStream.

**Parameters:**

- `raw` ({string:) - any} headers as returned by the C binding, or nil

**Returns:**

- {string: - string} lowercase names; repeats joined with ", "
- {string: - {string}} lowercase names; all values in order
