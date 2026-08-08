--- Extracting an executable's zip contents.
---
--- Split out of cosmic.embed for the 500-line cap. The extraction
--- itself is czip.extract (api-review: embed no longer reimplements
--- the loop or re-declares zip's records) — the zip-slip guard, the
--- upfront validation, and the mode masking all live there, once.

local czip = require("cosmic.zip")
local fs = require("cosmic.fs")

--- Options for extract (#1001: was a bare positional exe_path).
local record ExtractOptions
  --- Path to the executable to extract (default arg[-1], the running
  --- binary).
  exe_path: string
end

--- Extract the zip contents of a cosmic executable to a directory.
--- Creates the output directory if needed. Existing files are
--- overwritten. Returns the extracted file count (#1001: EmbedResult's
--- success-or-error-text-by-flag record is gone).
--- @param output_dir string Directory to extract into
--- @param opts ExtractOptions? exe_path: the executable to extract
--- @return integer | nil The extracted file count, or nil on failure
--- @return string? Error message on failure
local function extract(output_dir: string, opts?: ExtractOptions): integer | nil, string
  local exe_path = (opts and opts.exe_path) or arg[-1]

  if not exe_path then
    return nil, "error: could not determine executable path"
  end

  -- Open straight from the path: reading the whole executable into a
  -- Lua string first (czip.open_string) cost the binary's size in
  -- allocation per call. The failure branch re-probes with fs.read to
  -- keep the two documented messages distinguishable — an unreadable
  -- file stays "cannot read executable", a readable non-archive stays
  -- "no zip archive found".
  local archive_maybe = czip.open(exe_path)
  if not archive_maybe then
    if not fs.read(exe_path) then
      return nil, "error: cannot read executable '" .. exe_path .. "'"
    end
    return nil, "error: no zip archive found in '" .. exe_path .. "'"
  end
  local archive = archive_maybe

  -- The count czip.extract does not return: every non-directory entry
  -- is written, or the whole extraction fails before partial output.
  local entries, lerr = archive:list()
  if not entries then
    archive:close()
    return nil, "error: cannot list '" .. exe_path .. "': " ..
    (lerr or "unknown error")
  end
  local count = 0
  for _, entry in ipairs(entries) do
    if entry.name:sub(-1) ~= "/" then
      count = count + 1
    end
  end

  local ok, err = czip.extract(archive, output_dir)
  archive:close()
  if not ok then
    return nil, "error: " .. (err or "extract failed")
  end

  return count
end

local record ExtractModule
  type ExtractOptions = ExtractOptions
  extract: function(output_dir: string, opts?: ExtractOptions): integer | nil, string
end

local M: ExtractModule = {
  extract = extract,
}

return M
