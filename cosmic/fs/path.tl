--- Path manipulation functions for the filesystem module.
--- Pure string operations for dirname, basename, join, normalize, etc.
local unix = require("cosmo.unix")
local cosmo_path = require("cosmo.path")

--- Strip final component from path.
--- Examples: "/usr/lib" -> "/usr", "usr" -> ".", "/" -> "/"
--- @param str string The path to get the directory from
--- @return string The directory portion of the path
local function dirname(str: string): string
  return cosmo_path.dirname(str)
end

--- Return final component of path.
--- Examples: "/usr/lib" -> "lib", "/" -> "/", "." -> "."
--- @param str string The path to get the basename from
--- @return string The final component of the path
local function basename(str: string): string
  return cosmo_path.basename(str)
end

--- Concatenate path components.
--- Absolute paths in later arguments reset the result.
--- Nil arguments are skipped; exclusively nil returns nil.
--- @param ... string Path components to join
--- @return string The joined path
local function join(...: string): string
  return cosmo_path.join(...)
end

--- Check if a path is present — #988: was `exists` (rule 3).
--- Symbolic links are followed (uses stat): a symlink resolves to its target,
--- and returns true if the target exists. Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path exists
local function is_present(p: string): boolean
  return cosmo_path.exists(p)
end

--- Check if path is a regular file.
--- Symbolic links are followed (uses stat), matching POSIX `test -f`,
--- Python, and Node: a symlink to a regular file counts as a regular
--- file. Use is_link() to detect the symlink itself. Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path is a regular file
local function is_file(p: string): boolean
  local st = unix.stat(p)
  return st ~= nil and unix.S_ISREG(st:mode())
end

--- Check if path is a directory.
--- Symbolic links are followed (uses stat), matching POSIX `test -d`,
--- Python, and Node: a symlink to a directory counts as a directory.
--- Use is_link() to detect the symlink itself. Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path is a directory
local function is_dir(p: string): boolean
  local st = unix.stat(p)
  return st ~= nil and unix.S_ISDIR(st:mode())
end

--- Check if path is a symbolic link.
--- Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path is a symbolic link
local function is_link(p: string): boolean
  return cosmo_path.islink(p)
end

--- Return the drive letter (uppercased) when the path begins with a
--- Windows drive-letter root like "C:/" or "C:\". Drive-relative forms
--- ("C:foo") are not roots and return nil.
local function win_drive(p: string): string | nil
  local d = p:match("^(%a):[/\\]")
  if d then
    return d:upper()
  end
  return nil
end

--- Check whether a path is absolute on any supported OS.
--- Absolute forms: POSIX ("/usr/lib"), Windows drive-letter roots
--- ("C:/foo", "C:\foo"), and UNC roots ("\\server\share"). A single
--- leading backslash is NOT absolute: on POSIX, "\" is an ordinary
--- filename character, and cosmic runs the same code on every OS.
--- Drive-relative forms ("C:foo") are not absolute either.
--- @param p string The path to check
--- @return boolean True if the path is absolute
local function is_absolute(p: string): boolean
  if p:sub(1, 1) == "/" then
    return true
  end
  if p:sub(1, 2) == "\\\\" then
    return true
  end
  return win_drive(p) ~= nil
end

--- Split on the separator pattern and collapse "." and ".." components.
--- Rooted paths drop a leading ".."; relative paths preserve it.
local function collapse(p: string, rooted: boolean, pat: string): {string}
  local parts: {string} = {}
  local n = 0
  for part in p:gmatch(pat) do
    if part == "." then
      -- skip current dir
    elseif part == ".." then
      if n > 0 and parts[n] ~= ".." then
        parts[n] = nil
        n = n - 1
      elseif not rooted then
        -- for relative paths, preserve leading ..
        n = n + 1
        parts[n] = ".."
      end
      -- for rooted paths starting with /.., just ignore the ..
    else
      n = n + 1
      parts[n] = part
    end
  end
  return parts
end

--- Normalize path by removing `.` and `..` components without filesystem access.
--- Also removes redundant slashes. Pure string manipulation.
--- Examples: "/usr/./lib" -> "/usr/lib", "/usr/lib/../bin" -> "/usr/bin"
--- Windows-absolute inputs keep their root: drive-letter paths ("C:\foo",
--- "C:/foo") normalize to a forward-slash form with an uppercase drive
--- ("C:/foo"), and UNC paths ("\\server\share") keep the backslash form.
--- Elsewhere in a POSIX path, "\" is an ordinary filename character.
--- @param p string The path to normalize
--- @return string The normalized path
local function normalize(p: string): string
  if p == "" then
    return "."
  end

  -- Windows drive-letter root: both separators split the body, the
  -- result uses forward slashes (accepted by Windows and cosmopolitan),
  -- and the drive letter is canonicalized to upper case.
  local drive = win_drive(p)
  if drive then
    local parts = collapse(p:sub(4), true, "[^/\\]+")
    if #parts == 0 then
      return drive .. ":/"
    end
    return drive .. ":/" .. table.concat(parts, "/")
  end

  -- UNC root: keep the leading "\\" (so the result is still recognized
  -- as UNC) and the backslash separators.
  if p:sub(1, 2) == "\\\\" then
    return "\\\\" .. table.concat(collapse(p:sub(3), true, "[^/\\]+"), "\\")
  end

  -- Fast path: a path that is already normal — no redundant "//" or
  -- trailing "/", and no "." or ".." components — normalizes to itself,
  -- so return it without allocating the parts table and result string.
  -- The predicate is a conservative subset of "output == input" built
  -- from C-implemented full-string checks (no per-component Lua loop);
  -- anything it doesn't match falls through to the authoritative loop
  -- below, which stays the source of truth for correctness. Note a
  -- component merely containing dots (e.g. "..." or "a.b") is normal and
  -- correctly passes, since only exact "." / ".." segments are excluded.
  if p:sub(-1) ~= "/"
  and not p:find("//", 1, true)
  and p ~= "." and p:sub(1, 2) ~= "./"
  and p:sub(-2) ~= "/." and not p:find("/./", 1, true)
  and p ~= ".." and p:sub(1, 3) ~= "../"
  and p:sub(-3) ~= "/.." and not p:find("/../", 1, true) then
    return p
  end

  local rooted = p:sub(1, 1) == "/"
  local parts = collapse(p, rooted, "[^/]+")

  if rooted then
    if #parts == 0 then
      return "/"
    else
      return "/" .. table.concat(parts, "/")
    end
  else
    if #parts == 0 then
      return "."
    else
      return table.concat(parts, "/")
    end
  end
end

--- Convert relative path to absolute by prepending cwd (#988: was abspath).
--- Does NOT resolve symlinks or access filesystem (except to get cwd).
--- Windows-absolute paths (drive-letter or UNC roots, see is_absolute)
--- are already absolute and only get normalized — cwd is not prepended.
--- @param p string The path to make absolute
--- @return string The absolute path
local function absolute_path(p: string): string
  if p == "" then
    return unix.getcwd() or "."
  end
  if is_absolute(p) then
    return normalize(p)
  end
  local cwd = unix.getcwd()
  if not cwd then
    return normalize(p)
  end
  return normalize(cwd .. "/" .. p)
end

--- Root classification for relpath: paths under different roots (drive
--- letters, UNC shares, POSIX "/") have no relative form.
local function root_of(p: string): string
  local drive = win_drive(p)
  if drive then
    return drive .. ":"
  end
  if p:sub(1, 2) == "\\\\" then
    -- UNC: the root is the \\server\share pair — different shares have
    -- no relative form. An unparseable UNC prefix compares as itself.
    return p:match("^(\\\\[^/\\]+[/\\][^/\\]+)") or p
  end
  return "/"
end

--- Make path relative to another path (defaults to cwd; was relpath, #988).
--- Pure string manipulation - does not access the filesystem.
--- When the two paths live under different roots (different drive
--- letters, UNC vs drive, Windows vs POSIX), no relative path exists;
--- the normalized absolute target is returned instead.
--- @param p string The path to make relative
--- @param base string? The base path (defaults to cwd)
--- @return string The relative path
local function relative_path(p: string, base?: string): string
  -- Get absolute versions of both paths. When both p and the implicit
  -- base need cwd (relative p, no explicit base), fetch it once instead
  -- of once per absolute_path() call.
  local abs_p: string
  local abs_base: string
  if base then
    abs_p = absolute_path(p)
    abs_base = absolute_path(base)
  elseif is_absolute(p) then
    abs_p = normalize(p)
    abs_base = unix.getcwd() or "."
  else
    -- Fast path: when p never climbs above cwd, cwd's own components are
    -- always a strict prefix of normalize(cwd .. "/" .. p) and contribute
    -- nothing to the result, so the relative path is just normalize(p).
    -- The guard mirrors normalize()'s own "does this escape upward" check.
    local norm_p = normalize(p)
    if norm_p ~= ".." and norm_p:sub(1, 3) ~= "../" then
      return norm_p
    end
    local cwd = unix.getcwd() or "."
    abs_p = normalize(cwd .. "/" .. p)
    abs_base = cwd
  end

  local root = root_of(abs_p)
  if root ~= root_of(abs_base) then
    return abs_p
  end

  -- After normalize, drive-letter paths use "/" separators (the "C:"
  -- prefix survives splitting as an ordinary first component, so equal
  -- drives fall into the common prefix); UNC paths use "\".
  local pat = "[^/]+"
  if root:sub(1, 2) == "\\\\" then
    pat = "[^\\]+"
  end

  -- Split into components
  local function split_path(s: string): {string}
    local path_parts: {string} = {}
    for part in s:gmatch(pat) do
      table.insert(path_parts, part)
    end
    return path_parts
  end

  local p_parts = split_path(abs_p)
  local base_parts = split_path(abs_base)

  -- Find common prefix length
  local common_len = 0
  local max_common = math.min(#p_parts, #base_parts)
  for i = 1, max_common do
    if p_parts[i] == base_parts[i] then
      common_len = i
    else
      break
    end
  end

  -- Build relative path: go up from base, then down to target
  local rel_parts: {string} = {}

  -- Add ".." for each remaining component in base
  for _ = common_len + 1, #base_parts do
    table.insert(rel_parts, "..")
  end

  -- Add remaining components from target
  for i = common_len + 1, #p_parts do
    table.insert(rel_parts, p_parts[i])
  end

  if #rel_parts == 0 then
    return "."
  end

  return table.concat(rel_parts, "/")
end

--- Rejoin a dirname() result with a (possibly rewritten) basename.
--- dirname == "." means p had no directory component, so the root is
--- just root_base with nothing prepended; dirname == "/" means p was
--- directly under the filesystem root, so join()ing with "/" (rather
--- than the naive dir .. "/" .. root_base) avoids a doubled leading
--- slash ("//root_base").
local function join_dirname(dir: string, root_base: string): string
  if dir == "." then
    return root_base
  end
  return join(dir, root_base)
end

--- Split path into root and extension (was splitext, #988). The
--- extension includes the dot; the split is at the last dot in the
--- basename, and hidden files (leading .) have no extension.
--- Examples: "foo.txt" -> "foo", ".txt"; ".bashrc" -> ".bashrc", ""
--- @param p string The path to split
--- @return string The root portion (path without extension)
--- @return string The extension (including dot, or empty string)
local function split_extension(p: string): string, string
  local base = cosmo_path.basename(p)
  local dir = cosmo_path.dirname(p)

  -- Handle hidden files: if basename starts with . and has no other dot, no extension
  if base:sub(1, 1) == "." then
    local rest = base:sub(2)
    local dot_pos = rest:find("%.")
    if not dot_pos then
      -- Hidden file with no extension
      return p, ""
    end
    -- Hidden file with extension: find last dot in the non-hidden part
    local last_dot: integer = 0
    for i = #base, 2, -1 do
      if base:sub(i, i) == "." then
        last_dot = i
        break
      end
    end
    if last_dot > 0 then
      local extension = base:sub(last_dot)
      local root_base = base:sub(1, last_dot - 1)
      return join_dirname(dir, root_base), extension
    end
    return p, ""
  end

  -- Find last dot in basename
  local last_dot: integer = 0
  for i = #base, 1, -1 do
    if base:sub(i, i) == "." then
      last_dot = i
      break
    end
  end

  if last_dot == 0 or last_dot == 1 then
    -- No dot, or dot at start (shouldn't happen since we handled hidden files)
    return p, ""
  end

  local extension = base:sub(last_dot)
  local root_base = base:sub(1, last_dot - 1)

  return join_dirname(dir, root_base), extension
end

--- Return the current user's home directory.
--- Uses $HOME, falling back to $USERPROFILE Windows.
--- @return string | nil The home directory, or nil when unknown
--- @return string? Error message when no home directory is set
local function home(): string | nil, string
  local dir = os.getenv("HOME") or os.getenv("USERPROFILE")
  if not dir or dir == "" then
    return nil, "home: HOME is not set"
  end
  return dir
end

--- Expand a leading "~" to the home directory (was expanduser, #988).
--- Only bare "~" and "~/..." are expanded; "~user/..." forms and
--- paths without the prefix are returned unchanged, as is any path
--- when no home directory can be determined.
--- @param p string The path to expand
--- @return string The expanded path
local function expand_user(p: string): string
  if p ~= "~" and p:sub(1, 2) ~= "~/" then
    return p
  end
  local dir = home()
  if not dir then
    return p
  end
  if p == "~" then
    return dir
  end
  return cosmo_path.join(dir, p:sub(3))
end

--- Reject archive entry names that would escape an extraction root.
--- THE zip-slip guard: cosmic.zip, cosmic.tar and cosmic.embed all
--- extract archive-controlled names under a destination, and the three
--- private copies of this predicate had already drifted apart (empty
--- names, backslash policy). One definition, one place to fix the next
--- traversal variant.
---
--- Unsafe: empty names, absolute roots (/ or \ or a drive-letter
--- prefix), any ".." component on either separator ("..\evil" like
--- "../evil"), and control characters — a name with one travels into
--- line-oriented records (`--make fetch` logs unpack products one per
--- line), where a newline forges entries. Backslashes are otherwise
--- treated as separators, not refused: Windows-made archives use them
--- legitimately.
--- (was unsafe_entry_name, #988) @param name string Archive entry name
--- @return boolean true when the entry is unsafe to extract
local function is_unsafe_entry_name(name: string): boolean
  if name == "" then return true end
  if name:find("%c") then return true end
  -- Absolute roots escape the destination directory.
  if name:sub(1, 1) == "/" or name:sub(1, 1) == "\\" then return true end
  if name:match("^%a:") then return true end
  -- Normalize backslashes so ".." traversal is caught on either
  -- separator ("..\evil" like "../evil").
  local slashed = name:gsub("\\", "/")
  if slashed == ".." or slashed:match("^%.%./") or slashed:match("/%.%./")
  or slashed:match("/%.%.$") then
    return true
  end
  return false
end

local record FsPathModule
  is_unsafe_entry_name: function(name: string): boolean
  dirname: function(str: string): string
  basename: function(str: string): string
  join: function(...: string): string
  home: function(): string | nil, string
  expand_user: function(p: string): string
  is_present: function(path: string): boolean
  is_file: function(path: string): boolean
  is_dir: function(path: string): boolean
  is_link: function(path: string): boolean
  is_absolute: function(p: string): boolean
  normalize: function(p: string): string
  absolute_path: function(p: string): string
  relative_path: function(p: string, base?: string): string
  split_extension: function(p: string): string, string
  --- DEPRECATED aliases (#988); deleted at pin advance.
  unsafe_entry_name: function(name: string): boolean
  expanduser: function(p: string): string
  exists: function(path: string): boolean
  abspath: function(p: string): string
  relpath: function(p: string, base?: string): string
  splitext: function(p: string): string, string
end

local M: FsPathModule = {
  is_unsafe_entry_name = is_unsafe_entry_name,
  dirname = dirname,
  basename = basename,
  join = join,
  home = home,
  expand_user = expand_user,
  is_present = is_present,
  is_file = is_file,
  is_dir = is_dir,
  is_link = is_link,
  is_absolute = is_absolute,
  normalize = normalize,
  absolute_path = absolute_path,
  relative_path = relative_path,
  split_extension = split_extension,
  -- DEPRECATED aliases (#988); deleted at pin advance.
  unsafe_entry_name = is_unsafe_entry_name,
  expanduser = expand_user,
  exists = is_present,
  abspath = absolute_path,
  relpath = relative_path,
  splitext = split_extension,
}

return M
