# compress

 Compression and decompression utilities.
 Wraps DEFLATE in the three standard framings — zlib (default), gzip,
 and raw (headerless, as used inside ZIP files) — so output
 interoperates with standard tooling for each format (api-review-2,
 #590). Raw callers who need the original length carry it themselves
 and should checksum the output separately.

## Types

### CompressOptions

 Options for compress().

```teal
local record CompressOptions
  --  output framing; defaults to "zlib"
  format: Format
end
```

### DecompressOptions

 Options for decompress().

```teal
local record DecompressOptions
  --  input framing; defaults to "zlib"
  format: DecompressFormat
  --  cap on the decompressed size in bytes (default 64 MiB)
  max_output: integer
end
```

### CompressModule

```teal
local record CompressModule
  compress: function(data: string, opts?: CompressOptions): string
  decompress: function(data: string, opts?: DecompressOptions): string | nil, string
end
```

## Functions

### compress

```teal
function compress(data: string, opts?: CompressOptions): string
```

 Compress data using a standard framing.
 zlib (default) and gzip carry their own integrity checks and can be
 decompressed without knowing the original size. Raw is headerless
 DEFLATE, suitable for embedding into formats like ZIP files.

**Parameters:**

- `data` (string) - The data to compress
- `opts` (CompressOptions?) - format: "zlib" (default) | "gzip" | "raw"

**Returns:**

- string - The compressed data

### decompress

```teal
function decompress(data: string, opts?: DecompressOptions): string | nil, string
```

 Decompress data in a standard framing.
 The decompressed size need not be known in advance; output is bounded
 by max_output (default 64 MiB, enforced by the binding) so untrusted
 input cannot balloon memory.

**Parameters:**

- `data` (string) - The compressed data
- `opts` (DecompressOptions?) - format: "zlib" (default) | "gzip" | "raw" | "auto"; max_output: output byte cap

**Returns:**

- string - | nil The decompressed data, or nil on error
- string? - Error message if decompression failed
