--- Extract a Cosmic API surface from Teal sources embedded in a ZIP.
local surface = require("_tool.surface")
local zip = require("cosmic.zip")

local type Surface = surface.Surface

local function diagnostic(path: string, operation: string,
    detail: string): string
  return string.format("%s: %s failed: %s", path, operation,
    detail or "unknown error")
end

local function fail_after_close(archive: zip.Archive, path: string,
    operation: string, detail: string): nil, string
  local ok, close_err = archive:close()
  if not ok then
    return nil, diagnostic(path, "close", close_err)
  end
  return nil, diagnostic(path, operation, detail)
end

--- Read embedded Cosmic Teal sources and extract their API surface.
--- @param path ZIP archive path
--- @return Surface|nil Extracted surface, or nil on failure
--- @return string Diagnostic naming the archive path and failed operation
local function surface_of(path: string): Surface | nil, string
  local archive, open_err = zip.open(path, {mode = "read"})
  if not archive then
    return nil, diagnostic(path, "open", open_err)
  end

  local entries, list_err = archive:list()
  if not entries then
    return fail_after_close(archive, path, "list", list_err)
  end

  local sources: {string: string} = {}
  local source_count = 0
  for _, entry in ipairs(entries) do
    if entry.name:match("^%.tl/cosmic/.+%.tl$") then
      local contents, read_err = archive:read(entry.name)
      if not contents then
        return fail_after_close(archive, path, "read " .. entry.name,
          read_err)
      end
      sources[entry.name:sub(5)] = contents
      source_count = source_count + 1
    end
  end

  local close_ok, close_err = archive:close()
  if not close_ok then
    return nil, diagnostic(path, "close", close_err)
  end
  if source_count == 0 then
    return nil, diagnostic(path, "select sources",
      "no embedded .tl/cosmic/**.tl entries")
  end

  local found, extract_err = surface.extract(sources)
  if not found then
    return nil, diagnostic(path, "extract", extract_err)
  end
  return found
end

local record SurfaceArchiveModule
  surface_of: function(path: string): Surface | nil, string
end

local M: SurfaceArchiveModule = {surface_of = surface_of}
return M
