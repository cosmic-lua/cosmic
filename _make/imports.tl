--- The one place a source is scanned for `require` edges.
---
--- Four consumers want this answer and it must be the SAME answer: the
--- validator (which REFUSES a project over a cross-`cmd` import), the
--- dependency closure (which turns edges into prerequisites), the facts
--- writer (a closure per compiled file), and the fence (which will grant
--- reads from it). Each scanning for itself would drift -- one gaining
--- comment handling and a frontier anchor the others lack -- so the
--- same file could have different imports depending on who asked: a
--- commented-out require invisible to the gate and a phantom
--- prerequisite to the graph at the same time.
---
--- Scanning is also the model's hot loop: every consumer re-read and
--- re-matched every source, and the facts writer does it once per
--- compiled file. `of_file` reads and scans each path once per model
--- build; `forget` starts the next one.
---
--- What is deliberately NOT found: a computed require
--- (`require(name)`). A project that computes its module names has left
--- the shape the model describes, and the consequence is a denied read
--- rather than a wrong one.

local fs = require("cosmic.fs")

--- Skip a long bracket (`[[`, `[==[`, …) opening at `i`.
---
--- Used for long strings and, one character further in, long comments.
--- @param src string The source
--- @param i integer Index of the opening `[`
--- @return integer The index just past the close, or past end-of-source
local function past_long_bracket(src: string, i: integer): integer
  local eq = src:match("^%[(=*)%[", i)
  if not eq then
    return i + 1
  end
  local close = "]" .. eq .. "]"
  local at = src:find(close, i + #eq + 2, true)
  if not at then
    return #src + 1
  end
  return at + #close
end

--- Skip a short string opening at `i`, honouring backslash escapes.
--- @param src string The source
--- @param i integer Index of the opening quote
--- @return integer The index just past the closing quote
local function past_short_string(src: string, i: integer): integer
  local quote = src:sub(i, i)
  local n = #src
  local j = i + 1
  while j <= n do
    local c = src:sub(j, j)
    if c == quote then
      return j + 1
    end
    -- An unterminated string ends at the newline, the way Lua's own
    -- lexer would; scanning is best-effort over sources that may not
    -- even compile yet.
    if c == "\n" then
      return j
    end
    j = j + (c == "\\" and 2 or 1)
  end
  return n + 1
end

--- The literal `require("…")` targets in a source, in file order.
---
--- A scan and not a regex sweep, because the three shapes that fooled a
--- regex are all lexical: a require inside a `--[[ … ]]` block (a
--- line-comment strip removes only the opener's line, so the interior
--- still matched and REFUSED the project); a `--` inside a string
--- literal (which truncated the rest of the line, losing real requires);
--- and `myrequire("x")` (an identifier ending in the word). Walking
--- strings and comments as units answers all three by construction
--- rather than by a longer pattern.
--- @param src string The source text
--- @return {string} Imported module names, in file order
local function scan(src: string): {string}
  local out: {string} = {}
  local n = #src
  local i = 1
  while i <= n do
    local c = src:sub(i, i)
    if c == "-" and src:sub(i + 1, i + 1) == "-" then
      if src:match("^%[=*%[", i + 2) then
        i = past_long_bracket(src, i + 2)
      else
        i = src:find("\n", i, true) or n + 1
      end
    elseif c == "[" and src:match("^%[=*%[", i) then
      i = past_long_bracket(src, i)
    elseif c == '"' or c == "'" then
      i = past_short_string(src, i)
    elseif c:match("[%a_]") then
      local word = src:match("^[%a_][%w_]*", i)
      i = i + #word
      if word == "require" then
        local name = src:match("^%s*%(?%s*[\"']([%w_%.%-]+)[\"']", i)
        if name then
          out[#out + 1] = name
        end
      end
    else
      i = i + 1
    end
  end
  return out
end

--- Edges scanned so far this model build, by absolute path.
local cache: {string: {string}} = {}

--- Drop the memo. Called when a project is scanned, so the map's
--- lifetime is one model build: within a build the tree is a snapshot
--- and re-reading it can only cost time, across builds it may have
--- changed and re-reading is the point.
local function forget()
  cache = {}
end

--- The imports of a source file, read once per model build.
--- An unreadable file has no edges -- the validator reports missing
--- files by their own rule, not through this one.
--- @param path string Absolute path to the source
--- @return {string} Imported module names, in file order
local function of_file(path: string): {string}
  local hit = cache[path]
  if hit then
    return hit
  end
  local content = fs.read(path)
  local found = content and scan(content) or {}
  cache[path] = found
  return found
end

--- Non-import files a test declares it READS, from `--- reads: <path>`
--- doc-comment lines. The content key hashes only declared inputs, and
--- a ratchet test's subject (docs/decisions, .github/workflows) is no
--- import — undeclared, an edit to it would replay the test's cached
--- verdict instead of re-running it. Paths are relative to the project
--- root; a directory declares every file under it.
--- @param src string The file's contents
--- @return {string} Declared read paths, in file order
local function reads_scan(src: string): {string}
  local out: {string} = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    local path = line:match("^%-%-%- reads: (%S+)%s*$")
    if path then
      out[#out + 1] = path
    end
  end
  return out
end

--- The declared reads of a source file, expanded: each declared
--- directory becomes the sorted list of files under it, so the make
--- prerequisites and the content key see files, not directories --
--- a directory's mtime misses edits inside it, which a content key
--- must never do. A declared path that does not exist fails the scan
--- loudly: an input that cannot be hashed is a declaration gone stale.
--- @param root string Absolute project root
--- @param path string Source file path relative to root
--- @return {string} | nil Sorted file paths relative to root
--- @return string The error when a declaration names a missing path
local function reads_of_file(root: string, path: string): {string} | nil, string
  local content = fs.read(fs.join(root, path))
  if not content then
    return {}
  end
  local out: {string} = {}
  for _, declared in ipairs(reads_scan(content)) do
    local abs = fs.join(root, declared)
    if fs.is_dir(abs) then
      -- cast: `or` keeps the nil in the union
      local under = (fs.find(abs) or {}) as {string}
      for _, f in ipairs(under) do
        -- collect returns root-joined paths; keep them root-relative
        -- like every other project.mk entry
        out[#out + 1] = (f:sub(1, #root + 1) == root .. "/") and f:sub(#root + 2) or f
      end
    elseif fs.is_file(abs) then
      out[#out + 1] = declared
    else
      return nil, path .. " declares `reads: " .. declared ..
      "`, which does not exist"
    end
  end
  table.sort(out)
  return out
end

--- Names already folded into every step's content key
--- (`_cli/build/work.tl`'s `ENV_SWITCHES`, D18): `CI`, `COSMIC_COVERAGE`,
--- `COSMIC_FENCE`, `COSMIC_FIXPOINT`, `COSMIC_BENCHMARK_MIN_MS`.
--- Mirrored here rather than imported — this module has no dependency
--- on `_cli/build`, and the set is small and load-bearing enough that a
--- drift would show up as a refusal, not a silent gap. An `--- env:`
--- declaration naming one of these would stamp a value the reader
--- never sees: it is already in the key, and `COSMIC_COVERAGE`
--- specifically is rewritten per-lane by the runner
--- (`_tool/testrun.tl:54-68`) to an isolated per-test directory, so the
--- ambient value a declaration would hash is not even what the child runs
--- with.
local ENV_SWITCHES < const >: {string: boolean} = {
  CI = true,
  COSMIC_COVERAGE = true,
  COSMIC_FENCE = true,
  COSMIC_FIXPOINT = true,
  COSMIC_BENCHMARK_MIN_MS = true,
}

--- Environment variable names a test declares it READS, from
--- `--- env: <NAME> <NAME> ...` doc-comment lines — multi-token, unlike
--- `reads_scan`'s one-path-per-line grammar, because a test commonly
--- reads more than one variable at once (`FUZZ_SEED` and `FUZZ_ITERS`
--- together).
--- @param src string The file's contents
--- @return {string} Declared names, in file order, possibly repeated
local function env_scan(src: string): {string}
  local out: {string} = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    local rest = line:match("^%-%-%- env: (.+)$")
    if rest then
      for name in rest:gmatch("%S+") do
        out[#out + 1] = name
      end
    end
  end
  return out
end

--- The declared env reads of a source file: sorted, de-duplicated
--- names. A name that is not a valid identifier, or that names a D18
--- switch already in every step key, refuses loudly — the same
--- posture `reads_of_file` takes toward a stale path, because a
--- declaration the build cannot honor is a declaration gone stale.
--- @param root string Absolute project root
--- @param path string Source file path relative to root
--- @return {string} | nil Sorted, de-duplicated names
--- @return string The error when a declared name is invalid
local function env_of_file(root: string, path: string): {string} | nil, string
  local content = fs.read(fs.join(root, path))
  if not content then
    return {}
  end
  local seen: {string: boolean} = {}
  local out: {string} = {}
  for _, name in ipairs(env_scan(content)) do
    if not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
      return nil, path .. " declares `env: " .. name ..
      "`, which is not a valid environment variable name"
    end
    if ENV_SWITCHES[name] then
      return nil, path .. " declares `env: " .. name ..
      "`, which is already a D18 step-key switch (stamped in every " ..
      "step already)"
    end
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local record ImportsModule
  scan: function(src: string): {string}
  of_file: function(path: string): {string}
  reads_of_file: function(root: string, path: string): {string} | nil, string
  env_scan: function(src: string): {string}
  env_of_file: function(root: string, path: string): {string} | nil, string
  forget: function()
end

local M: ImportsModule = {
  scan = scan,
  of_file = of_file,
  reads_of_file = reads_of_file,
  env_scan = env_scan,
  env_of_file = env_of_file,
  forget = forget,
}

return M
