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
  mode: integer
  method: string
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

### EmbedDirHandle

 Directory handle whose `read` exposes the dirent d_type (unix.DT_DIR /
 DT_REG / DT_LNK / ... / DT_UNKNOWN) where the filesystem supports it,
 letting collect_dir skip a stat(2) call for entries d_type already
 identifies as neither a directory nor a regular file.

```teal
local record EmbedDirHandle
  read: function(self): string, integer
  close: function(self)
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
  run: function(paths: {string}, output?: string, exe_path?: string): EmbedResult
  extract: function(output_dir: string, exe_path?: string): EmbedResult
  unsafe_entry: function(name: string): boolean
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

### unsafe_entry

```teal
function unsafe_entry(name: string): boolean
```

 Report whether a zip entry name would escape the extraction root
 (zip-slip). Rejects absolute paths — POSIX (`/x`), Windows/UNC
 (`\x`, `\\server\share`), and drive-letter (`C:\x`, `C:/x`, `C:x`) —
 and any `..` traversal component. Both `/` and `\` are treated as
 separators, since cosmic executables also extract on Windows where a
 `..\evil` entry would otherwise slip past a POSIX-only guard.

**Parameters:**

- `name` (string) - Archive entry name

**Returns:**

- boolean - true if the entry is unsafe to extract

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
