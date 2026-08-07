--- Extracting an executable's zip contents.
---
--- Split out of cosmic.embed for the 500-line cap. The extraction
--- itself is czip.extract (api-review: embed no longer reimplements
--- the loop or re-declares zip's records) — the zip-slip guard, the
--- upfront validation, and the mode masking all live there, once.

local czip = require("cosmic.zip")
local fs = require("cosmic.fs")

--- Result returned from embed and extract operations.
local record EmbedResult
  ok: boolean
  message: string
  file_count: integer
end

--- Extract the zip contents of a cosmic executable to a directory.
--- Creates the output directory if needed. Existing files are overwritten.
--- @param output_dir string Directory to extract into
--- @param exe_path string Path to the executable to extract (defaults to arg[-1])
--- @return EmbedResult Result with ok status, message, and file count
local function extract(output_dir: string, exe_path?: string): EmbedResult
  exe_path = exe_path or arg[-1]

  if not exe_path then
    return {ok = false, message = "error: could not determine executable path", file_count = 0}
  end

  -- Open straight from the path: reading the whole executable into a
  -- Lua string first (czip.open_bytes) cost the binary's size in
  -- allocation per call. The failure branch re-probes with fs.read to
  -- keep the two documented messages distinguishable — an unreadable
  -- file stays "cannot read executable", a readable non-archive stays
  -- "no zip archive found".
  local archive_maybe = czip.open(exe_path)
  if not archive_maybe then
    if not fs.read(exe_path) then
      return {ok = false, message = "error: cannot read executable '" .. exe_path .. "'", file_count = 0}
    end
    return {ok = false, message = "error: no zip archive found in '" .. exe_path .. "'", file_count = 0}
  end
  local archive = archive_maybe

  -- The count czip.extract does not return: every non-directory entry
  -- is written, or the whole extraction fails before partial output.
  local count = 0
  for _, entry in ipairs(archive:list()) do
    if entry.name:sub(-1) ~= "/" then
      count = count + 1
    end
  end

  local ok, err = czip.extract(archive, output_dir)
  archive:close()
  if not ok then
    return {ok = false, message = "error: " .. (err or "extract failed"), file_count = 0}
  end

  return {
    ok = true,
    message = "extracted " .. count .. " file(s) to " .. output_dir,
    file_count = count,
  }
end

local record ExtractModule
  type EmbedResult = EmbedResult
  extract: function(output_dir: string, exe_path?: string): EmbedResult
end

local M: ExtractModule = {
  extract = extract,
}

return M
