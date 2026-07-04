-- type declarations for cosmo.path
-- GENERATED from cosmopolitan's definitions.lua by lib/types/gentype.tl.
-- Do not edit by hand. Regenerate with: bin/make regen-types

local record path
  --- Strips final component of path, e.g.
  ---     path      │ dirname
  ---     ───────────────────
  ---     .         │ .
  ---     ..        │ .
  ---     /         │ /
  ---     usr       │ .
  ---     /usr/     │ /
  ---     /usr/lib  │ /usr
  ---     /usr/lib/ │ /usr
  dirname: function(str: string): string
  --- Returns final component of path, e.g.
  ---     path      │ basename
  ---     ─────────────────────
  ---     .         │ .
  ---     ..        │ ..
  ---     /         │ /
  ---     usr       │ usr
  ---     /usr/     │ usr
  ---     /usr/lib  │ lib
  ---     /usr/lib/ │ lib
  basename: function(str: string): string
  --- Concatenates path components, e.g.
  ---     x         │ y        │ joined
  ---     ─────────────────────────────────
  ---     /         │ /        │ /
  ---     /usr      │ lib      │ /usr/lib
  ---     /usr/     │ lib      │ /usr/lib
  ---     /usr/lib  │ /lib     │ /lib
  --- You may specify 1+ arguments.
  --- Specifying no arguments will raise an error. If `nil` arguments are specified,
  --- then they're skipped over. If exclusively `nil` arguments are passed, then `nil`
  --- is returned. Empty strings behave similarly to `nil`, but unlike `nil` may
  --- coerce a trailing slash.
  join: function(str?: string, ...: string): string | nil
  --- Returns `true` if path exists.
  --- This function is inclusive of regular files, directories, and special files.
  --- Symbolic links are followed are resolved. On error, `false` is returned.
  exists: function(path: string): boolean
  --- Returns `true` if path exists and is regular file.
  --- Symbolic links are not followed. On error, `false` is returned.
  isfile: function(path: string): boolean
  --- Returns `true` if path exists and is directory.
  --- Symbolic links are not followed. On error, `false` is returned.
  isdir: function(path: string): boolean
  --- Returns `true` if path exists and is symbolic link.
  --- Symbolic links are not followed. On error, `false` is returned.
  islink: function(path: string): boolean
end

return path
