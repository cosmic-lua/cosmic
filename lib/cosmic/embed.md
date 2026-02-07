# embed

 Embed files and directories into a cosmic executable.

 cosmic is an executable zip — a native binary with a zip archive appended.
 Files in the archive are accessible at /zip/ paths from Lua code. The
 entry point is /zip/main.lua, configured by /zip/.args.

 Create a custom executable:

   mkdir myapp
   echo 'print("hello world")' > myapp/main.lua
   cosmic --embed myapp/ --output hello
   ./hello

 Directory contents are stored relative to the directory root, so
 myapp/main.lua becomes /zip/main.lua in the resulting executable.
 Embedding a main.lua overrides the default entry point.

 The resulting executable keeps cosmic's bundled libraries, so embedded
 code can require("cosmic.fetch"), require("lsqlite3"), etc.

 Extract an executable's zip contents for inspection or modification:

   cosmic --extract myapp/
   # edit myapp/main.lua
   cosmic --embed myapp/ --output myapp

 This roundtrips: extract produces exactly the files that embed consumes.

## Types

### EmbedResult

 Result returned from embed and extract operations.

```teal
local record EmbedResult
  ok: boolean
  message: string
  file_count: integer
end
```

### AddOptions

 Options for adding files to a ZIP archive.

```teal
local record AddOptions
  mode: number
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

### ZipStat

 Stat record for zip file metadata.

```teal
local record ZipStat
  mode: number
end
```

### ZipReader

 Reader interface for reading files from a ZIP archive.

```teal
local record ZipReader
  list: function(self: ZipReader): {string}
  read: function(self: ZipReader, name: string): string | nil, string | nil
  stat: function(self: ZipReader, name: string): ZipStat | nil
  close: function(self: ZipReader)
end
```

### FileToEmbed

```teal
local record FileToEmbed
  path: string
  content: string
  stored_name: string
  mode: number
end
```

### EmbedModule

```teal
local record EmbedModule
  run: function(paths: {string}, output?: string, exe_path?: string): EmbedResult
  extract: function(output_dir: string, exe_path?: string): EmbedResult
end
```

## Functions

### run

```teal
function run(paths: {string}, output?: string, exe_path?: string): EmbedResult
```

 Embed files and directories into a copy of the cosmic executable.
 Creates a new executable with the given paths appended to the zip archive.
 Paths can be files or directories. Directories are walked recursively and
 their contents are stored relative to the directory root. Files are stored
 with their given path (leading / stripped).

**Parameters:**

- `paths` ({string}) - List of file or directory paths to embed
- `output` (string) - Output path for the new executable (defaults to "cosmic")
- `exe_path` (string) - Path to the source executable (defaults to arg[-1])

**Returns:**

- EmbedResult - Result with ok status, message, and file count

### extract

```teal
function extract(output_dir: string, exe_path?: string): EmbedResult
```

 Extract the zip contents of a cosmic executable to a directory.
 Creates the output directory if needed. Existing files are overwritten.

**Parameters:**

- `output_dir` (string) - Directory to extract into
- `exe_path` (string) - Path to the executable to extract (defaults to arg[-1])

**Returns:**

- EmbedResult - Result with ok status, message, and file count
