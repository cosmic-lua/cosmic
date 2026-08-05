# embed

 Embed files and directories into a cosmic executable.

 cosmic is an executable zip — a native binary with a zip archive appended.
 Files in the archive are accessible at /zip/ paths from Lua code. The
 entry point is /zip/main.lua, configured by /zip/.args.

 Any file can be embedded (Lua source, data files, binaries, etc.), but
 the entry point must be a plain Lua file named main.lua. Teal files are
 not compiled at runtime, so compile them first:

   cosmic --compile myapp.tl > myapp/main.lua

 Create a custom executable:

   mkdir myapp
   echo 'print("hello world")' > myapp/main.lua
   cosmic --embed myapp/ --output hello
   ./hello

 Directory contents are stored relative to the directory root, so
 myapp/main.lua becomes /zip/main.lua in the resulting executable.
 Embedding a main.lua overrides the default entry point. A custom
 entry is stored byte-identical at /zip/main.user.lua behind a
 generated /zip/main.lua that puts the zip root on the module path
 and installs the cosmic runtime .tl searcher : modules
 embedded beside main.lua resolve with the same guarantees as
 `cosmic script.tl`, no loader boilerplate. An unmodified
 dispatcher main.lua (extract/re-embed roundtrip) and an
 already-wrapped entry pass through unchanged.

 The resulting executable keeps cosmic's bundled libraries, so embedded
 code can require("cosmic.fetch"), require("lsqlite3"), etc.

 Extract an executable's zip contents for inspection or modification:

   cosmic --extract myapp/
   # edit myapp/main.lua
   cosmic --embed myapp/ --output myapp

 This roundtrips: extract produces exactly the files that embed consumes.

## Types

### Options

 Options for run().

```teal
local record Options
  --  Output path for the new executable (default "cosmic").
  output: string
  --  Path to the source executable to copy (default arg[-1], the
  --  running binary).
  exe_path: string
  --  Strip the base executable down to the floor (cosmic.embed.floor)
  --  before adding the caller's files. Everything the base carried
  --  that is not on the floor is a tool for BUILDING programs, not a
  --  runtime an artifact needs.
  strip: boolean
  --  Module namespaces these files supply themselves (`cosmic`, ...).
  --  A supplied namespace leaves the strip floor, so the artifact ships
  --  one definition of it instead of the project's winning on
  --  `package.path` while the base's rides along underneath.
  provides: {string: boolean}
  --  Fixed modification time for every added entry, so two builds of
  --  one tree agree byte-for-byte.
  mtime: integer
end
```

### AddOptions

 Options for adding files to a ZIP archive.

```teal
local record AddOptions
  mode: integer
  method: string
  mtime: integer
end
```

### ZipAppender

 Appender interface for modifying a ZIP archive in-place.

```teal
local record ZipAppender
  add: function(self: ZipAppender, name: string, content: string, options?: AddOptions): boolean, string
  remove: function(self: ZipAppender, name: string): boolean, string
  close: function(self: ZipAppender)
end
```

### ZipEntry

 Directory entry returned by ZipReader:list().

```teal
local record ZipEntry
  name: string
  size: integer
  mode: integer
end
```

### ZipReader

 Reader interface for reading files from a ZIP archive.

```teal
local record ZipReader
  list: function(self: ZipReader): {ZipEntry}
  read: function(self: ZipReader, name: string): string | nil, string | nil
  close: function(self: ZipReader)
end
```

### DirEntry

```teal
local record DirEntry
  name: string
  kind: integer
end
```

### FileToEmbed

```teal
local record FileToEmbed
  path: string
  content: string
  stored_name: string
  mode: integer
end
```

### EmbedModule

```teal
local record EmbedModule
  EPOCH: integer
  embed: function(paths: {string}, opts?: Options): EmbedResult
  --  DEPRECATED alias for embed() (api-review-8 transition)
  run: function(paths: {string}, opts?: Options): EmbedResult
  extract: function(output_dir: string, exe_path?: string): EmbedResult
  unsafe_entry: function(name: string): boolean
end
```

## Functions

### embed

```teal
function embed(paths: {string}, opts?: Options): EmbedResult
```

 Embed files and directories into a copy of the cosmic executable.
 Creates a new executable with the given paths appended to the zip archive.
 Paths can be files or directories. Directories are walked recursively and
 their contents are stored relative to the directory root. Files are stored
 with their given path (leading / stripped).

**Parameters:**

- `paths` ({string}) - List of file or directory paths to embed
- `opts` (Options?) - output, exe_path, stripping, reproducibility

**Returns:**

- EmbedResult - Result with ok status, message, and file count
