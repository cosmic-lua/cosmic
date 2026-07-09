# compress

 Compression and decompression utilities.
 Provides zlib and raw deflate compression with consistent error handling.

## Types

### CompressModule

```teal
local record CompressModule
  compress: function(data: string): string
  uncompress: function(data: string, max_output?: number): string | nil, string
  deflate: function(data: string): string | nil, string
  inflate: function(data: string, max_output?: number): string | nil, string
end
```

## Functions

### compress

```teal
function compress(data: string): string
```

 Compress data using standard zlib framing.
 The zlib format carries its own integrity check (Adler-32), and the
 output interoperates with other zlib tooling. It can be decompressed
 without knowing the original size.

**Parameters:**

- `data` (string) - The data to compress

**Returns:**

- string - The compressed data

### uncompress

```teal
function uncompress(data: string, max_output?: number): string | nil, string
```

 Decompress zlib-compressed data.
 The decompressed size need not be known in advance; output is bounded
 by max_output (default 64 MiB, enforced by the binding) so untrusted
 input cannot balloon memory.

**Parameters:**

- `data` (string) - The compressed data (from compress())
- `max_output` (number?) - Cap on the decompressed size in bytes

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
function inflate(data: string, max_output?: number): string | nil, string
```

 Decompress raw deflate data.
 Expects data from deflate() with the 4-byte size prefix.
 Maximum decompressed size: ~4GB (limited by 32-bit size prefix).
 The size prefix is attacker-controlled in untrusted input, so it is
 validated BEFORE the output buffer is allocated: a declared size larger
 than max_output (when given), or implausibly large for the compressed
 payload (beyond DEFLATE's ~1032:1 maximum ratio), is rejected without
 allocating, and the binding additionally caps decompression at the
 declared size. Output that does not match the declared size exactly is
 reported as corrupt.
 Note: Only compatible with data produced by deflate() in this module.

**Parameters:**

- `data` (string) - The compressed data with size prefix
- `max_output` (number?) - Reject a declared size larger than this many bytes

**Returns:**

- string - | nil The decompressed data, or nil on error
- string? - Error message if decompression failed
