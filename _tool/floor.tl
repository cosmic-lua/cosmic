--- Shared bytes-in, bytes-out helper for a committed floor.
---
--- `_build/casts.tl` and `_build/public_surface.tl` each read and write
--- one committed file: a ceiling of `as` casts, a set of public module
--- names. Both already read and write it with `cosmic.literal`, and
--- both do it the same way -- parse the file, forwarding `noun` and
--- `on_duplicate`; format the value back out. This module is that
--- shared shape, and nothing more: it owns bytes and resolution
--- FORWARDING only. It holds no comparison and no judgment -- whether
--- 7 casts is worse than 5, whether a missing name is a failure -- that
--- stays in the gate that reads the value back. `_build/ratchet.tl`
--- makes the same split between reading a table and judging its rows.
---
---     local floor = require("_tool.floor")
---     local data = check.must(floor.read(path))
---     local ok, err = floor.write(path, data)

local literal = require("cosmic.literal")

--- Options forwarded to `cosmic.literal.parse_file`.
local record Options
  --- What to call the file in errors. Default "literal".
  noun: string
  --- Resolves a key repeated within one table instead of refusing it.
  --- Default nil: a repeated key is refused, naming both lines. Same
  --- shape as `cosmic.literal`'s own resolver (called with the value
  --- already stored for the key and the newly parsed one for the SAME
  --- key in the SAME table; its return value is stored as-is).
  on_duplicate: function(key: string, first: any, second: any): any
end

--- Read a committed floor as data.
--- @param path string The floor file
--- @param opts Options? noun: file kind in errors; on_duplicate: resolves
--- a repeated key instead of refusing it
--- @return {string: any}|nil The declared table
--- @return string The error message when unreadable or not a literal
local function read(path: string, opts?: Options): {string: any} | nil, string
  return literal.parse_file(path, {
      noun = opts and opts.noun,
      on_duplicate = opts and opts.on_duplicate,
    })
end

--- Write a value to a committed floor.
--- @param path string The floor file
--- @param value any The table to write
--- @return boolean Whether the write succeeded
--- @return string The error message on failure
local function write(path: string, value: any): boolean, string
  return literal.format_file(path, value)
end

--- Parse floor bytes already in hand, without touching the filesystem.
--- The text-level counterpart to `read`, for a caller that owns the
--- read/write itself and needs the encoding forwarded on a string it
--- holds — coverage's baseline reads once, then parses that same text
--- twice (the ratchet and the lowered-row diff), so it cannot re-read
--- per parse.
--- @param text string The floor's contents
--- @param opts Options? noun: file kind in errors; on_duplicate: resolves
--- a repeated key instead of refusing it
--- @return {string: any}|nil The declared table
--- @return string The error message when the text is not a literal
local function parse(text: string, opts?: Options): {string: any} | nil, string
  return literal.parse(text, {
      noun = opts and opts.noun,
      on_duplicate = opts and opts.on_duplicate,
    })
end

--- Format a value as floor bytes, without touching the filesystem. The
--- text-level counterpart to `write`, for a caller that owns the write.
--- @param value any The table to render
--- @return string|nil The rendered floor, or nil when outside the domain
--- @return string The error message when `value` is not representable
local function format(value: any): string | nil, string
  return literal.format(value)
end

local record FloorModule
  type Options = Options
  read: function(path: string, opts?: Options): {string: any} | nil, string
  write: function(path: string, value: any): boolean, string
  parse: function(text: string, opts?: Options): {string: any} | nil, string
  format: function(value: any): string | nil, string
end

local M: FloorModule = {
  read = read,
  write = write,
  parse = parse,
  format = format,
}

return M
