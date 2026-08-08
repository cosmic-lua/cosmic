# tar

## Types

### ExtractOptions

 Options for extract().

```teal
local record ExtractOptions
  --  Cap on the unpacked archive size in bytes (default 512 MiB): the
  --  bound the gunzip step enforces, so a corrupt or malicious archive
  --  cannot balloon memory (api-review #996: was a private constant
  --  while zip's cap was an option).
  max_archive_bytes: integer
end
```

### Header

```teal
local record Header
  name: string
  mode: integer
  size: integer
  typeflag: string
  linkname: string
end
```

### TarModule

```teal
local record TarModule
  extract: function(archive: string, destdir: string, opts?: ExtractOptions): boolean, string
end
```

## Functions

### extract

```teal
function extract(archive: string, destdir: string,
    opts?: ExtractOptions): boolean, string
```

 Extract a tarball into destdir. Gzip compression is detected from
 the file's magic bytes, so `.tar.gz` and plain `.tar` both extract
 with the same call (api-review #996: this used to gunzip
 unconditionally, so an uncompressed tarball was unreadable).

**Parameters:**

- `archive` (string) - Path to the .tar.gz or .tar file
- `destdir` (string) - Directory to extract into (created if needed)
- `opts` (ExtractOptions?) - max_archive_bytes: unpacked size cap

**Returns:**

- boolean - true when every entry was written
- string? - Error message on failure
