--- TRANSITIONAL embed compatibility (#1001; DELETE this module at the
--- pin advance): the pin boot-executes `_make`'s artifact staging and
--- `_cli`'s --embed/--extract handlers against ITS embedded
--- cosmic.embed — `embed`/EmbedResult{ok, message, file_count},
--- positional extract exe_path, `EPOCH` — while the tree's record has
--- `write`/`extract` returning `integer | nil, string`, an
--- ExtractOptions record, and `EPOCH_SECONDS`. These wrappers detect
--- the generation at runtime and normalize both the arguments and the
--- result, so one caller shape runs under both.
local embed = require("cosmic.embed")

local record EmbedCompat
  write: function(paths: {string}, opts?: embed.Options): integer | nil, string
  extract: function(output_dir: string, exe_path?: string): integer | nil, string
  EPOCH_SECONDS: integer
end

local embed_any = embed as {string: any} -- cast: transitional dual-shape module

--- Normalize a pin-shaped EmbedResult (or a tree-shaped pair) into
--- the pair.
local function counted(r: any, err: any): integer | nil, string
  if r == nil then
    return nil, err as string -- cast: transitional dual-shape result
  end
  if r is number then
    return math.tointeger(r)
  end
  local rec = r as {string: any} -- cast: transitional dual-shape result
  if rec["ok"] then
    return rec["file_count"] as integer -- cast: transitional dual-shape result
  end
  return nil, rec["message"] as string -- cast: transitional dual-shape result
end

local function compat_write(paths: {string}, opts?: embed.Options): integer | nil, string
  -- cast: transitional dual-shape call
  local call = (embed_any["write"] or embed_any["embed"]) as
  function({string}, embed.Options): (any, any)
  return counted(call(paths, opts))
end

local function compat_extract(output_dir: string, exe_path?: string): integer | nil, string
  if embed_any["write"] then
    -- The tree generation: extract takes an options record.
    -- cast: transitional dual-shape call
    local call = embed_any["extract"] as
    function(string, {string: string}): (any, any)
    return counted(call(output_dir, exe_path and {exe_path = exe_path} or nil))
  end
  -- cast: transitional dual-shape call
  local call = embed_any["extract"] as function(string, string): (any, any)
  return counted(call(output_dir, exe_path))
end

local M: EmbedCompat = {
  write = compat_write,
  extract = compat_extract,
  -- cast: transitional dual-shape member
  EPOCH_SECONDS = (embed_any["EPOCH_SECONDS"] or embed_any["EPOCH"]) as integer,
}

return M
