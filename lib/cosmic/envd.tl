--- Load environment variables from an embedded env.d directory.
---
--- Each file in the env.d directory sets an environment variable.
--- The filename is the variable name; the file content (trimmed) is the value.
--- Existing environment variables are NOT overwritten — the real environment
--- always takes precedence.
---
--- This follows the systemd/container convention where a directory of
--- single-value files represents environment variables. It's useful for
--- embedding credentials (API keys, tokens) into a cosmic executable:
---
---   mkdir env.d
---   echo -n 'sk-ant-...' > env.d/ANTHROPIC_API_KEY
---   cosmic --embed env.d
---
--- At startup, call envd.load() to read /zip/embed/env.d/ and set any
--- variables not already present in the environment.
---
--- Filenames must match [A-Za-z_][A-Za-z0-9_]* (standard env var names).
--- Dotfiles, invalid names, and empty/whitespace-only files are skipped.
--- Lines starting with # in the file content are NOT treated as comments —
--- the entire content (trimmed) is the value.
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local env = require("cosmic.env")

local ENVD_PATH = "/zip/embed/env.d"

--- Result returned from load operations.
local record LoadResult
  count: integer
  source: string
end

--- Load env vars from a directory. Each file's name is the var name,
--- content (trimmed) is the value. Skips dotfiles and names that aren't
--- valid env var names. Does not overwrite existing env vars.
---
--- When COSMIC_DEBUG is set, prints the name (not value) and source path
--- of each variable set to stderr.
---
--- @param dir string The directory to read env files from
--- @return LoadResult Result with count of variables set and source path
local function load_dir(dir: string): LoadResult
  local result: LoadResult = {count = 0, source = dir}
  local debug = env.get("COSMIC_DEBUG") ~= nil

  local dh, dh_err = fs.opendir(dir)
  if not dh then
    if debug then
      io.stderr:write("[envd] skip " .. dir .. ": " .. (dh_err or "not found") .. "\n")
    end
    return result
  end

  local names: {string} = {}
  while true do
    local name = dh:read()
    if not name then break end
    if name ~= "." and name ~= ".." then
      names[#names + 1] = name
    end
  end
  dh:close()
  table.sort(names)

  for _, name in ipairs(names) do
    -- skip dotfiles and names that aren't valid env var names
    if not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
      if debug then
        io.stderr:write("[envd] skip invalid name: " .. name .. "\n")
      end
    elseif env.get(name) then
      if debug then
        io.stderr:write("[envd] skip " .. name .. ": already set in environment\n")
      end
    else
      local path = fs.join(dir, name)
      local content = cio.slurp(path)
      if content then
        -- trim leading/trailing whitespace (trailing newlines are common)
        local value = content:match("^%s*(.-)%s*$") or ""
        if value ~= "" then
          env.set(name, value)
          result.count = result.count + 1
          if debug then
            io.stderr:write("[envd] set " .. name .. " (source: " .. path .. ")\n")
          end
        elseif debug then
          io.stderr:write("[envd] skip " .. name .. ": empty value\n")
        end
      elseif debug then
        io.stderr:write("[envd] skip " .. name .. ": unreadable\n")
      end
    end
  end

  if debug then
    io.stderr:write("[envd] loaded " .. tostring(result.count) .. " variable(s) from " .. dir .. "\n")
  end

  return result
end

--- Load env vars from the embedded /zip/embed/env.d directory.
--- Call this early in startup, before code that depends on the variables.
--- @return LoadResult Result with count of variables set and source path
local function load(): LoadResult
  return load_dir(ENVD_PATH)
end

local record EnvdModule
  load: function(): LoadResult
  load_dir: function(dir: string): LoadResult
end

local M: EnvdModule = {
  load = load,
  load_dir = load_dir,
}

return M
