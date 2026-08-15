# codec

 Encoding and decoding utilities: bytes in, bytes out.
 Provides hex, base64, base32, and Latin-1 codecs with consistent
 error handling, plus CRC-32 checksums (checksums are
 encoding-adjacent error detection, not crypto — see cosmic.hash for
 digests). Lua VALUE serialization is not a byte codec and lives in
 cosmic.literal (format/parse).

## Types

### CodecModule

```teal
local record CodecModule
  encode_hex: function(data: string): string
  decode_hex: function(hex: string): string | nil, string
  encode_base64: function(data: string): string
  decode_base64: function(str: string): string | nil, string
  encode_base64url: function(data: string): string
  decode_base64url: function(str: string): string | nil, string
  encode_base32: function(data: string): string
  decode_base32: function(str: string): string | nil, string
  crc32: function(data: string, initial?: integer): integer
  crc32c: function(data: string, initial?: integer): integer
  encode_latin1: function(str: string): string | nil, string
  decode_latin1: function(data: string): string
end
```

## Functions

### encode_hex

```teal
function encode_hex(data: string): string
```

 Encode a string as hexadecimal.
 Each byte becomes two lowercase hex characters.

**Parameters:**

- `data` (string) - The binary data to encode

**Returns:**

- string - The hexadecimal representation

### decode_hex

```teal
function decode_hex(hex: string): string | nil, string
```

 Decode a hexadecimal string to binary data.
 Accepts both uppercase and lowercase hex characters.

**Parameters:**

- `hex` (string) - The hexadecimal string to decode

**Returns:**

- string - | nil The decoded binary data, or nil on error
- string? - Error message if decoding failed

### encode_base64

```teal
function encode_base64(data: string): string
```

 Encode binary data as base64.
 Uses standard base64 encoding (RFC 4648).

**Parameters:**

- `data` (string) - The binary data to encode

**Returns:**

- string - The base64 encoded string

### decode_base64

```teal
function decode_base64(str: string): string | nil, string
```

 Decode a base64 string to binary data.
 Accepts standard base64 encoding with or without padding.

**Parameters:**

- `str` (string) - The base64 string to decode

**Returns:**

- string - | nil The decoded binary data, or nil on error
- string? - Error message if decoding failed

### encode_base64url

```teal
function encode_base64url(data: string): string
```

 Encode binary data as base64url (RFC 4648 section 5).
 The URL- and filename-safe variant: "-" and "_" replace "+" and
 "/", and no "=" padding is emitted.

**Parameters:**

- `data` (string) - The binary data to encode

**Returns:**

- string - The base64url encoded string

### decode_base64url

```teal
function decode_base64url(str: string): string | nil, string
```

 Decode a base64url string to binary data.
 Accepts the URL-safe alphabet ("-" and "_") with or without "="
 padding. Standard-alphabet characters ("+", "/") are rejected.

**Parameters:**

- `str` (string) - The base64url string to decode

**Returns:**

- string - | nil The decoded binary data, or nil on error
- string? - Error message if decoding failed

### encode_base32

```teal
function encode_base32(data: string): string
```

 Encode binary data as base32.
 Uses lowercase base32 alphabet (0-9a-z excluding i, l, o, u).

**Parameters:**

- `data` (string) - The binary data to encode

**Returns:**

- string - The base32 encoded string

### decode_base32

```teal
function decode_base32(str: string): string | nil, string
```

 Decode a base32 string to binary data.
 Uses lowercase base32 alphabet (0-9a-z excluding i, l, o, u).

**Parameters:**

- `str` (string) - The base32 string to decode

**Returns:**

- string - | nil The decoded binary data, or nil on error
- string? - Error message if decoding failed

### crc32

```teal
function crc32(data: string, initial?: integer): integer
```

 Compute the CRC-32 checksum of data (ISO 3309 / "Phil Katz" CRC,
 as used by zip, zlib, and gzip; the same value zip.EntryStat reports).
 Checksums are error-detection codes, not cryptographic digests —
 for those, see cosmic.hash.digest.
 Pass a previous result as initial to checksum a stream
 incrementally: crc32(b, crc32(a)) == crc32(a .. b).

**Parameters:**

- `data` (string) - The data to checksum
- `initial` (integer?) - Checksum to continue from (default 0)

**Returns:**

- integer - The CRC-32 checksum as an unsigned 32-bit integer

### crc32c

```teal
function crc32c(data: string, initial?: integer): integer
```

 Compute the CRC-32C (Castagnoli) checksum of data, the variant
 used by iSCSI, ext4, and LevelDB. Same contract as crc32.

**Parameters:**

- `data` (string) - The data to checksum
- `initial` (integer?) - Checksum to continue from (default 0)

**Returns:**

- integer - The CRC-32C checksum as an unsigned 32-bit integer

### encode_latin1

```teal
function encode_latin1(str: string): string | nil, string
```

 Encode a UTF-8 string as Latin-1 (ISO-8859-1).
 Characters outside the Latin-1 range will cause an error.

**Parameters:**

- `str` (string) - The UTF-8 string to encode

**Returns:**

- string - | nil The Latin-1 encoded bytes, or nil on error
- string? - Error message if encoding failed

### decode_latin1

```teal
function decode_latin1(data: string): string
```

 Decode Latin-1 (ISO-8859-1) bytes to a UTF-8 string.

**Parameters:**

- `data` (string) - The Latin-1 bytes to decode

**Returns:**

- string - The UTF-8 string
