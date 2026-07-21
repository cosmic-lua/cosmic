-- #744 instrumentation harness (throwaway; not shipped).
--
-- Wraps the global io.open for the duration of a single strict compile so we
-- capture the EXACT errno of every failed file open tl.search_module does
-- while resolving requires. The offline lane's "module not found" surfaces
-- only when tl.search_module exhausts its path with every candidate open
-- failing; this records what those failures actually were (transient
-- EMFILE/ENFILE/EACCES vs a plain ENOENT miss), which strace would perturb.
--
-- Drop-in for `cosmic --include-dir lib --compile-strict <file>`: emits the
-- compiled Lua to stdout on success (build proceeds unchanged), diagnostics
-- to stderr. Invoked as: cosmic lib/io-log.lua <file>

local input = arg[1]
assert(input, "usage: io-log.lua <file.tl>")

local real_open = io.open

-- Record every failed open, keyed by errno. .tl/.lua candidates only, to keep
-- the noise down (tl probes each path root for both).
local fails = {}      -- errno -> count
local nonenoent = {}  -- list of "path errno msg" for anything that is NOT ENOENT

io.open = function(name, mode, ...)
  local f, err, errno = real_open(name, mode, ...)
  if not f and type(name) == "string" then
    local tail = name:sub(-3)
    if tail == ".tl" or name:sub(-4) == ".lua" then
      local key = tostring(errno)
      fails[key] = (fails[key] or 0) + 1
      if errno ~= 2 then -- 2 == ENOENT, the benign "not at this path" miss
        nonenoent[#nonenoent + 1] =
          ("path=%s errno=%s msg=%s"):format(name, tostring(errno), tostring(err))
      end
    end
  end
  return f, err, errno
end

local teal = require("cosmic.teal")
local r = teal.compile(input, { include_dirs = { "lib" }, strict = true })

io.open = real_open

-- Any non-ENOENT open failure is the smoking gun regardless of compile
-- outcome; dump it loudly with the file being compiled for correlation.
if #nonenoent > 0 then
  io.stderr:write(("IOOPENFAIL while compiling %s:\n"):format(input))
  for _, line in ipairs(nonenoent) do
    io.stderr:write("  " .. line .. "\n")
  end
end

if not r.ok then
  -- On failure, also dump the errno histogram so an all-ENOENT exhaustion
  -- (module genuinely unresolvable) is distinguishable from a transient one.
  local parts = {}
  for k, v in pairs(fails) do
    parts[#parts + 1] = ("errno %s x%d"):format(k, v)
  end
  io.stderr:write(("COMPILEFAIL %s | failed-opens: %s\n")
    :format(input, #parts > 0 and table.concat(parts, ", ") or "none"))
  io.stderr:write(teal.format_issues(r.errors) .. "\n")
  os.exit(1)
end

io.write(r.code)
