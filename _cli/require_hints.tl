--- Enhanced require with helpful error messages.
--- Intercepts module-not-found errors and suggests similar modules.

local original_require = require

--- Cached module mapping, built lazily on first use.
local module_map: {string: string} = nil

--- Check if a module exists without loading it.
--- @param name string Module name to check
--- @return boolean True if module can be loaded
local function module_exists(name: string): boolean
  if package.preload[name] then
    return true
  end
  -- Check package.path for .lua and .tl files. cosmic.string is
  -- required lazily: this only runs on the require-failure path, and a
  -- boot-time require would put the module on the boot surface.
  local str = original_require("cosmic.string")
  for path_pattern in package.path:gmatch("[^;]+") do
    local file_path = str.replace(path_pattern, "?", (name:gsub("%.", "/")))
    local f = io.open(file_path, "r")
    if f then
      f:close()
      return true
    end
  end
  return false
end

--- Build module mapping from package.preload and package.path.
--- Maps short names to full module names (e.g., "argon2" -> "cosmo.argon2",
--- "json" -> "cosmic.json").
--- Probes known cosmic.* module names so fuzzy matching covers modules loaded
--- from disk as well (e.g., "cosmic.jsn" -> "cosmic.json").
local function build_module_map(): {string: string}
  if module_map then
    return module_map
  end

  module_map = {}

  -- Scan package.preload for cosmo.* and cosmic.* modules
  for name, _ in pairs(package.preload) do
    local short = name:match("^cosmo%.(.+)$") or name:match("^cosmic%.(.+)$")
    if short and not short:match("%.") then
      -- Only map top-level modules (not submodules like cosmo.foo.bar)
      if not module_map[short] then
        module_map[short] = name
      end
    end
  end

  -- Probe known cosmic module short names via package.path to cover modules
  -- that live on disk rather than in package.preload (e.g., cosmic.json).
  -- This list mirrors the standard library table in CLAUDE.md.
  local known_cosmic: {string} = {
    "args", "benchmark", "child", "codec", "compress", "doc", "docs",
    "embed", "env", "envd", "example", "fetch", "format", "fs", "fuzzy",
    "getopt", "hash", "html", "io", "ip", "json", "landlock", "net",
    "pledge", "poll", "proc", "quicksand", "rand", "re", "require",
    "sandbox", "shm", "signal", "sqlite", "sse", "string", "sys",
    "syslog", "teal", "testrun", "time", "tty", "unveil", "url", "user",
    "uuid", "zip",
  }
  for _, short_name in ipairs(known_cosmic) do
    if not module_map[short_name] then
      local full = "cosmic." .. short_name
      if module_exists(full) then
        module_map[short_name] = full
      end
    end
  end

  return module_map
end

--- Find similar modules using Levenshtein distance.
--- @param name string The requested module name
--- @param max_distance integer Maximum edit distance to consider (default 3)
--- @return {string} List of similar full module names, sorted by distance
local function find_similar(name: string, max_distance?: integer): {string}
  max_distance = max_distance or 3
  local results: {{string, integer}} = {} -- {full_name, distance}

  -- Collect all known full module names (from module_map values and preload)
  -- to avoid duplicate work in inner loops.
  local seen_full: {string: boolean} = {}
  local candidates: {{string, string}} = {} -- {full_name, short_name_or_full}

  for short, full in pairs(build_module_map()) do
    if not seen_full[full] then
      seen_full[full] = true
      table.insert(candidates, {full, short})
    end
  end
  for full, _ in pairs(package.preload) do
    if (full:match("^cosmo%.") or full:match("^cosmic%.")) and not seen_full[full] then
      seen_full[full] = true
      table.insert(candidates, {full, full})
    end
  end

  -- Compare against both the short name and the full qualified name.
  -- This catches typos in either the prefix (e.g. "cosm.json") or the
  -- suffix (e.g. "cosmic.jsn" -> "cosmic.json", distance 1).
  -- cosmic.fuzzy is required lazily, like cosmic.string above: this
  -- only runs on the require-failure path, and a boot-time require
  -- would put the module on every invocation's boot surface (#973).
  local fuzzy = original_require("cosmic.fuzzy")
  for _, pair in ipairs(candidates) do
    local full = pair[1]
    local short = pair[2]
    local dist_short = fuzzy.distance(name:lower(), short:lower())
    local dist_full = fuzzy.distance(name:lower(), full:lower())
    local dist = math.min(dist_short, dist_full)
    if dist <= max_distance then
      table.insert(results, {full, dist})
    end
  end

  -- Sort by distance, then alphabetically
  table.sort(results, function(a: {string, integer}, b: {string, integer}): boolean
      if a[2] ~= b[2] then
        return a[2] < b[2]
      end
      return a[1] < b[1]
    end)

  -- Extract just the names
  local names: {string} = {}
  for _, r in ipairs(results) do
    table.insert(names, r[1])
  end

  return names
end

--- Format a helpful error message for module not found.
--- @param name string The requested module name
--- @return string Enhanced error message with suggestions
local function format_error(name: string): string
  local lines: {string} = {}
  table.insert(lines, "module '" .. name .. "' not found")
  table.insert(lines, "")

  -- Check for exact short name match first
  local aliases = build_module_map()
  local alias = aliases[name]
  if alias and module_exists(alias) then
    table.insert(lines, "Did you mean?")
    table.insert(lines, "  " .. alias)
    table.insert(lines, "")
    table.insert(lines, "Try: require(\"" .. alias .. "\")")
    return table.concat(lines, "\n")
  end

  -- Check if cosmo.name or cosmic.name exists exactly
  local cosmo_name = "cosmo." .. name
  local cosmic_name = "cosmic." .. name
  if module_exists(cosmo_name) then
    table.insert(lines, "Did you mean?")
    table.insert(lines, "  " .. cosmo_name)
    table.insert(lines, "")
    table.insert(lines, "Try: require(\"" .. cosmo_name .. "\")")
    return table.concat(lines, "\n")
  end
  if module_exists(cosmic_name) then
    table.insert(lines, "Did you mean?")
    table.insert(lines, "  " .. cosmic_name)
    table.insert(lines, "")
    table.insert(lines, "Try: require(\"" .. cosmic_name .. "\")")
    return table.concat(lines, "\n")
  end

  -- Try fuzzy matching
  local similar = find_similar(name, 3)
  if #similar > 0 then
    table.insert(lines, "Did you mean?")
    -- Show up to 3 suggestions
    for i = 1, math.min(3, #similar) do
      table.insert(lines, "  " .. similar[i])
    end
    table.insert(lines, "")
    table.insert(lines, "Try: require(\"" .. similar[1] .. "\")")
    return table.concat(lines, "\n")
  end

  -- No suggestions found
  table.insert(lines, "Modules use the 'cosmo.*' or 'cosmic.*' namespace.")
  table.insert(lines, "")
  table.insert(lines, "Use 'cosmic --docs' to list available modules.")

  return table.concat(lines, "\n")
end

--- Check if error message indicates module not found.
--- Matches both Lua's "module 'x' not found" and Teal loader's
--- "module not found: 'x'" formats.
--- @param err string Error message
--- @return boolean True if this is a module-not-found error
local function is_module_not_found(err: string): boolean
  return err:match("module '[^']+' not found") ~= nil
  or err:match("module not found: '[^']+'") ~= nil
end

--- Extract module name from require error.
--- Handles both Lua's "module 'x' not found" and Teal loader's
--- "module not found: 'x'" formats.
--- @param err string Error message
--- @return string Module name, or nil if not found
local function extract_module_name(err: string): string | nil
  return err:match("module '([^']+)' not found")
  or err:match("module not found: '([^']+)'")
end

--- Enhanced require function that provides helpful suggestions.
--- @param name string Module name to require
--- @return any The loaded module
local function enhanced_require(name: string): any
  local ok, result = pcall(original_require, name)
  if ok then
    return result
  end

  local err = tostring(result)
  if is_module_not_found(err) then
    local requested = extract_module_name(err) or name
    error(format_error(requested), 2)
  end

  -- Re-raise original error for non-module-not-found errors
  error(result, 2)
end

--- Install enhanced require globally.
--- Call this early in startup to enable helpful error messages.
local function install()
  _G.require = enhanced_require as function(string): any -- cast: function shape
end

--- Restore original require.
--- Useful for testing or disabling enhanced errors.
local function uninstall()
  _G.require = original_require
end

local record RequireModule
  install: function()
  uninstall: function()
  module_exists: function(name: string): boolean
  format_error: function(name: string): string
end

local M: RequireModule = {
  install = install,
  uninstall = uninstall,
  module_exists = module_exists,
  format_error = format_error,
}

return M
