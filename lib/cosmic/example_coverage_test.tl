#!/usr/bin/env cosmic
--- Example-per-public-module ratchet (issue #566): every public module
--- ships a runnable *_example.tl. Modules that predate the ratchet live
--- on the shrink-only allowlist below; #509 tracks burning it down.
---
--- The ratchet has three teeth:
--- - a public module neither exampled nor allowlisted fails (a NEW
---   public module cannot ship without an example);
--- - an allowlist entry that HAS gained an example fails (delete the
---   entry — the list may only shrink);
--- - an allowlist entry that is no longer public fails (demoted or
---   renamed modules must leave the list).
---
--- Coverage is read from the docs index embedded in the binary, which
--- merges each X_example.tl into module X (and shard examples like
--- quicksand/netns_example.tl into cosmic.<name>.<shard>).
local check = require("cosmic.check")
local manifest = require("cosmic.public")
local doc = require("cosmic.doc")

-- Shrink only. Never add an entry; delete each one as #509 lands its
-- example. (31 of 46 public modules at ratchet birth.)
local MISSING_ALLOWED: {string} = {
  "benchmark",
  "check",
  "codec",
  "compress",
  "doc",
  "errno",
  "example",
  "format",
  "fuzzy",
  "hash",
  "html",
  "ip",
  "proc",
  "rand",
  "re",
  "sse",
  "string",
  "sys",
  "syslog",
  "teal",
  "time",
  "tty",
  "url",
  "user",
  "uuid",
  "zip",
}

local index, ierr = doc.embedded_index()
local idx = check.must(index,
  "docs index must be embedded (run via the binary): " .. tostring(ierr))

--- True when the module (or any shard beneath it) carries examples in
--- the embedded docs index.
local function has_example(name: string): boolean
  local entry = idx.modules["cosmic." .. name]
  if entry and entry.examples and #entry.examples > 0 then
    return true
  end
  local prefix = "cosmic." .. name .. "."
  for mod_name, mod_doc in pairs(idx.modules) do
    if mod_name:sub(1, #prefix) == prefix
    and mod_doc.examples and #mod_doc.examples > 0 then
      return true
    end
  end
  return false
end

local allowed: {string: boolean} = {}
for _, name in ipairs(MISSING_ALLOWED) do
  assert(not allowed[name], "duplicate allowlist entry: " .. name)
  allowed[name] = true
end

local function test_every_public_module_has_example_or_waiver()
  local missing: {string} = {}
  for _, name in ipairs(manifest.public) do
    if not allowed[name] and not has_example(name) then
      missing[#missing + 1] = name
    end
  end
  table.sort(missing)
  assert(#missing == 0,
    "public modules without a *_example.tl (write one; the allowlist is "
    .. "closed to new entries): " .. table.concat(missing, ", "))
end
test_every_public_module_has_example_or_waiver()

local function test_allowlist_only_shrinks()
  local stale: {string} = {}
  for _, name in ipairs(MISSING_ALLOWED) do
    if has_example(name) then
      stale[#stale + 1] = name
    end
  end
  table.sort(stale)
  assert(#stale == 0,
    "allowlist entries that now HAVE examples — delete them: "
    .. table.concat(stale, ", "))
end
test_allowlist_only_shrinks()

local function test_allowlist_entries_are_public()
  local public_set: {string: boolean} = {}
  for _, name in ipairs(manifest.public) do
    public_set[name] = true
  end
  local gone: {string} = {}
  for _, name in ipairs(MISSING_ALLOWED) do
    if not public_set[name] then
      gone[#gone + 1] = name
    end
  end
  table.sort(gone)
  assert(#gone == 0,
    "allowlist entries that are not public modules — delete them: "
    .. table.concat(gone, ", "))
end
test_allowlist_entries_are_public()
