--- Fuzz properties for cosmic.tar's extract(): the two promises are
--- "corrupt input fails loudly" (never throws, a false return names
--- what failed) and "no write ever escapes the destination directory".
---
--- Archive construction mirrors the helpers in cosmic/tar_test.tl —
--- those are local to that file, so this one rebuilds the same
--- minimal, correctly-checksummed 512-byte-header archives rather than
--- reaching into it.
--- env: FUZZ_SEED FUZZ_ITERS

local check = require("cosmic.check")
local driver = require("_fuzz.driver")
local fs = require("cosmic.fs")
local tar = require("cosmic.tar")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local BLOCK = 512

-- ---- archive construction (same shapes as cosmic/tar_test.tl) ----

local function pad(s: string, len: integer): string
  return s .. string.rep("\0", len - #s)
end

local function tar_header(name: string, mode: integer, size: integer,
    typeflag: string, linkname: string): string
  local h = pad(name, 100)
  .. pad(string.format("%07o", mode), 8)
  .. pad("0000000", 8) -- uid
  .. pad("0000000", 8) -- gid
  .. pad(string.format("%011o", size), 12)
  .. pad("00000000000", 12) -- mtime
  .. "        " -- checksum placeholder: 8 spaces while summing
  .. typeflag
  .. pad(linkname, 100)
  .. pad("ustar", 6)
  .. "00"
  h = pad(h, BLOCK)
  local sum = 0
  for i = 1, BLOCK do
    sum = sum + h:byte(i)
  end
  return h:sub(1, 148) .. string.format("%06o\0 ", sum) .. h:sub(157)
end

local function tar_entry(name: string, content: string, mode: integer,
    typeflag: string, linkname: string): string
  local out = tar_header(name, mode, #content, typeflag, linkname)
  if #content > 0 then
    local blocks = math.ceil(#content / BLOCK)
    out = out .. content .. string.rep("\0", blocks * BLOCK - #content)
  end
  return out
end

--- A pax record's length prefix counts the whole record including
--- itself, so the length is found at a fixpoint (copied from
--- cosmic/tar_test.tl's pax_record).
local function pax_record(key: string, value: string): string
  local rec = key .. "=" .. value .. "\n"
  local len = #rec
  while true do
    local total = #tostring(len) + 1 + #rec
    if total == len then break end
    len = total
  end
  return string.format("%d %s", len, rec)
end

--- A regular-file entry whose real name arrives via a pax path
--- override rather than the fixed 100-byte header field: the override
--- carries the name unmodified (no NUL truncation, no length cap), so
--- it is how a hostile name -- including one holding an embedded NUL --
--- reaches extract() intact.
local function hostile_entry(name: string, content: string): string
  local pax = pax_record("path", name)
  return tar_entry("placeholder", pax, fs.octal("644"), "x", "")
  .. tar_entry("placeholder", content, fs.octal("644"), "0", "")
end

--- A regular-file entry whose hostile name is written straight into the
--- fixed 100-byte header name field, with no pax override -- so
--- extract()'s handling of the ordinary name path is fuzzed too, not
--- only the pax-encoded one. Not valid for a name holding an embedded
--- NUL: the fixed field truncates at the first NUL (see str_field in
--- cosmic/tar.tl), so that class can only reach extract() intact via
--- hostile_entry's pax override.
local function hostile_entry_plain(name: string, content: string): string
  return tar_entry(name, content, fs.octal("644"), "0", "")
end

local function end_marker(): string
  return string.rep("\0", 2 * BLOCK)
end

local NAME_ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

--- A short, filesystem-safe random name for a benign filler entry.
--- @param max_len integer The longest name to produce
--- @return string The generated name
local function random_name(max_len: integer): string
  local n = math.random(1, max_len)
  local out: {string} = {}
  for i = 1, n do
    local at = math.random(1, #NAME_ALPHABET)
    out[i] = NAME_ALPHABET:sub(at, at)
  end
  return table.concat(out)
end

--- Build a small archive of 2-4 regular files with random names, sizes
--- and modes, then a proper end-of-archive marker.
--- @return string The archive bytes
local function random_valid_archive(): string
  local parts: {string} = {}
  for _ = 1, math.random(2, 4) do
    parts[#parts + 1] = tar_entry(random_name(12), driver.bytes(200),
      math.random(0, 511), "0", "")
  end
  parts[#parts + 1] = end_marker()
  return table.concat(parts)
end

-- ---- properties 1 & 2: totality under mutation and truncation ----

--- extract() must never throw, and a false return must name what
--- failed. Writes `bytes` to a fresh subdirectory of TEST_TMPDIR and
--- extracts into a sibling fresh subdirectory, both named by `tag` so
--- the three properties in this file never collide with each other or
--- with a previous iteration.
--- @param tag string A property-and-iteration-unique name fragment
--- @param bytes string The archive bytes to extract
--- @return boolean True when the totality bar held
--- @return string What failed, when it did not
local function totality_check(tag: string, bytes: string): boolean, string
  local archive = fs.join(tmpdir, tag .. ".tar")
  local ok_w, err_w = fs.write(archive, bytes)
  if not ok_w then
    return false, "setup: writing the archive failed: " .. tostring(err_w)
  end
  local dest = fs.join(tmpdir, tag .. "-dest")
  local ok, err = tar.extract(archive, dest)
  if ok == true then
    return true
  end
  if ok == false then
    if type(err) ~= "string" or err == "" then
      return false, "extract returned false with no message"
    end
    return true
  end
  return false, "extract's first return was neither true nor false: " .. tostring(ok)
end

local mutation_iteration = 0

local function test_mutation_totality()
  local ok, msg = driver.run({
      name = "tar_mutation_totality",
      gen = function(): string
        return driver.mutate(random_valid_archive(), math.random(1, 16))
      end,
      check = function(input: string): boolean, string
        mutation_iteration = mutation_iteration + 1
        return totality_check("tar-mutation-" .. mutation_iteration, input)
      end,
    })
  check.truthy(ok, msg)
end
test_mutation_totality()

local truncation_iteration = 0

local function test_truncation_totality()
  local ok, msg = driver.run({
      name = "tar_truncation_totality",
      gen = function(): string
        local archive = random_valid_archive()
        -- A cut at #archive itself is the untruncated archive; bias
        -- toward the interesting range by excluding it.
        local at = math.random(0, #archive - 1)
        return archive:sub(1, at)
      end,
      check = function(input: string): boolean, string
        truncation_iteration = truncation_iteration + 1
        return totality_check("tar-truncation-" .. truncation_iteration, input)
      end,
    })
  check.truthy(ok, msg)
end
test_truncation_totality()

-- ---- property 3: no write ever escapes destdir ----

-- Hostile member names, each delivered via a correctly checksummed
-- entry through the pax path override or the plain header name field
-- (see gen_hostile_entry). is_unsafe_entry_name is expected to refuse
-- every one of these before any filesystem write is attempted; the
-- property does not assume that -- it watches the disk.
local HOSTILE_NAMES = {
  "../x",
  "a/../../x",
  "/x",
  "good\0evil",
  string.rep("../", 6) .. "x", -- a long ..-chain
}

-- destdir nests this many levels below the case root, so that even a
-- hostile name this property's own corpus can produce (the 6-level
-- ..-chain above) lands inside the case root -- the tree this test
-- walks -- rather than climbing out of it, if the guard were ever to
-- fail. This is containment for the test itself, not a claim about
-- what the guard allows.
local DEST_NESTING = "L1/L2/L3/L4/L5/L6/L7/L8"

--- Build a hostile-named entry, alternating at random between the pax
--- path-override delivery and the plain header-name-field delivery. A
--- name with an embedded NUL always goes through pax -- the fixed
--- field would truncate it at the NUL before it ever reached
--- extract()'s unsafe-name check.
--- @param name string The hostile member name to deliver
--- @return string The entry bytes
local function gen_hostile_entry(name: string): string
  if name:find("\0", 1, true) or math.random(2) == 1 then
    return hostile_entry(name, driver.bytes(16))
  end
  return hostile_entry_plain(name, driver.bytes(16))
end

--- Build an archive mixing a few benign filler entries with one to
--- three hostile-named entries, all correctly checksummed. Each hostile
--- entry independently picks pax or plain-header delivery (see
--- gen_hostile_entry), so both paths into extract() get covered across
--- the run.
--- @return string The archive bytes
local function gen_no_escape_archive(): string
  local parts: {string} = {}
  for _ = 1, math.random(0, 2) do
    parts[#parts + 1] = tar_entry(random_name(10), driver.bytes(16), fs.octal("644"), "0", "")
  end
  for _ = 1, math.random(1, 3) do
    local name = HOSTILE_NAMES[math.random(1, #HOSTILE_NAMES)]
    parts[#parts + 1] = gen_hostile_entry(name)
  end
  for _ = 1, math.random(0, 2) do
    parts[#parts + 1] = tar_entry(random_name(10), driver.bytes(16), fs.octal("644"), "0", "")
  end
  parts[#parts + 1] = end_marker()
  return table.concat(parts)
end

local escape_iteration = 0

--- The containment walk covers only the case_root tree (case_root and
--- everything under it, per DEST_NESTING) -- not TEST_TMPDIR itself,
--- which also holds this test's own archive and directory fixtures and
--- so cannot be walked as "everything must be under dest" without
--- false positives. That narrowing has a blind spot: an absolute-name
--- escape ("/x") or a ".."-chain deeper than DEST_NESTING would land
--- outside case_root entirely and go unobserved by this walk. For
--- those two classes the property below degrades to proving only that
--- extract() did not throw -- not that nothing actually escaped. A
--- loud-rejection property for the absolute-name class is a separate,
--- not-yet-specced piece of work.
local function test_no_escape()
  local ok, msg = driver.run({
      name = "tar_no_escape",
      gen = gen_no_escape_archive,
      check = function(input: string): boolean, string
        escape_iteration = escape_iteration + 1
        local case_root = fs.join(tmpdir, "tar-noescape-" .. escape_iteration)
        local dest = fs.join(case_root, DEST_NESTING)
        local archive = fs.join(tmpdir, "noescape-" .. escape_iteration .. ".tar")
        local ok_w, err_w = fs.write(archive, input)
        if not ok_w then
          return false, "setup: writing the archive failed: " .. tostring(err_w)
        end
        -- extract()'s own return is not this property: a hostile entry
        -- is expected to make it fail (checked by cosmic/tar_test.tl).
        -- What matters here is only where bytes actually landed.
        local _ok, _err = tar.extract(archive, dest)
        local escaped: {string} = {}
        local walked = fs.visit(case_root, function(e: fs.Entry, acc: {string})
            local p = e.path
            -- p is fine when it IS dest, sits under dest, or is one of
            -- the L1/L2/... ancestor directories make_dirs created on
            -- the way down to dest -- only something outside that
            -- whole chain is a real escape.
            local under_dest = p == dest or p:sub(1, #dest + 1) == dest .. "/"
            local ancestor_of_dest = dest:sub(1, #p + 1) == p .. "/"
            if not under_dest and not ancestor_of_dest then
              acc[#acc + 1] = p
            end
          end, escaped)
        if walked == nil then
          return true -- the case root was never created: nothing escaped
        end
        if #escaped > 0 then
          return false, string.format("escaped outside %s: %s", dest, table.concat(escaped, ", "))
        end
        return true
      end,
    })
  check.truthy(ok, msg)
end
test_no_escape()
