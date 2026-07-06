# compress

 Compression and decompression utilities.
 Provides zlib and raw deflate compression with consistent error handling.

## Types

### CompressModule

```teal
local record CompressModule
  compress: function(data: string): string
  uncompress: function(data: string): string | nil, string
  deflate: function(data: string): string | nil, string
  inflate: function(data: string): string | nil, string
end
```

## Functions

### compress

```teal
function compress(data: string): string
```

 Compress data using zlib (with header).
 The compressed output includes size information and can be decompressed
 without knowing the original size.

**Parameters:**

- `data` (string) - The data to compress

**Returns:**

- string - The compressed data

### uncompress

```teal
function uncompress(data: string): string | nil, string
```

 Decompress zlib-compressed data.

**Parameters:**

- `data` (string) - The compressed data (from compress())

**Returns:**

- string - | nil The decompressed data, or nil on error
- string? - Error message if decompression failed

### deflate

```teal
function deflate(data: string): string | nil, string
```

 Compress data using raw deflate (no header).
 The output is prefixed with a 4-byte little-endian size to enable
 decompression without knowing the original size.
 Maximum input size: ~4GB (limited by 32-bit size prefix).
 Note: The output format is specific to this module and is not compatible
 with standard raw deflate streams. Use compress/uncompress for
 interoperable zlib format.

**Parameters:**

- `data` (string) - The data to compress

**Returns:**

- string - | nil The compressed data with size prefix, or nil on error
- string? - Error message if input exceeds size limit

### inflate

```teal
function inflate(data: string): string | nil, string
```

 Decompress raw deflate data.
 Expects data from deflate() with the 4-byte size prefix.
 Maximum decompressed size: ~4GB (limited by 32-bit size prefix).
 Note: Only compatible with data produced by deflate() in this module.

**Parameters:**

- `data` (string) - The compressed data with size prefix

**Returns:**

- string - | nil The decompressed data, or nil on error
- string? - Error message if decompression failed
