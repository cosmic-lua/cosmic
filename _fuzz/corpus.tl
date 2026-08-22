--- Corpus persistence for fuzz properties.
--- A property's corpus is a flat directory of content-addressed files,
--- one per minimized failing input, colocated with the fuzz test that
--- found them (`<test dir>/testdata/<property>/<sha256>`). Every run
--- replays that directory before it generates anything, so a bug found
--- once is a permanent regression instead of a seed number somebody has
--- to transcribe into a test by hand.
---
--- Environment: FUZZ_SAVE=1 turns writing on (it is off by default and
--- CI never sets it, so a run never mutates the tree unless asked).
--- FUZZ_CORPUS_DIR relocates the corpus root, which is how the tests
--- here point it at TEST_TMPDIR.
---
--- Replay reports through its own formatter: a stored input has no
--- seed, no iteration and no draw count, so it names `corpus=<file>`
--- where a generated failure names `iteration=`. The two tokens never
--- share a message, so grepping either never false-hits the other.

local codec = require("cosmic.codec")
local detail = require("_fuzz.detail")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")

--- Where one property's corpus lives.
--- FUZZ_CORPUS_DIR overrides the root; otherwise the corpus sits beside
--- the fuzz test file that owns it, so the mechanism works unchanged in
--- any project using this driver.
--- @param name string The property name
--- @return string The corpus directory for that property
local function dir_for(name: string): string
  local root = env.get("FUZZ_CORPUS_DIR")
  if root then
    return fs.join(root, name)
  end
  return fs.join(fs.dirname(arg[0]), "testdata", name)
end

--- Format the one message shape a corpus failure reports.
--- @param name string The property name
--- @param basename string The corpus file that failed, or "" when there is none
--- @param input string The failing input
--- @param what string What the property reported, or the thrown error
--- @return string The failure message
local function corpus_failure(
    name: string, basename: string, input: string, what: string
  ): string
  return string.format("%s: corpus=%s input(base64)=%s: %s",
    name, basename, codec.encode_base64(input), what)
end

--- Check every stored input for one property, in sorted order.
--- Returns immediately when the property has no corpus directory, which
--- is the common case: one boolean probe and nothing else. The budget
--- hook is armed and disarmed through the caller's own functions, so
--- this module needs nothing from the driver it is called by.
--- @param name string The property name
--- @param check function The property: function(input: string): boolean, string
--- @param budget integer VM instructions check() may spend per input
--- @param arm function Arms the budget hook: function(budget: integer): boolean
--- @param disarm function Turns the budget hook off: function()
--- @return boolean True when every stored input held
--- @return string The failure message, or "" when there was nothing to report
local function replay(
    name: string,
    check: function(input: string): boolean, string,
    budget: integer,
    arm: function(budget: integer): boolean,
    disarm: function()
  ): boolean, string
  local dir = dir_for(name)
  if not fs.is_dir(dir) then
    return true, ""
  end
  local found, err = fs.find(dir, {recursive = false, sorted = true})
  if not found then
    return false, corpus_failure(name, "", "",
      "corpus listing failed: " .. tostring(err))
  end
  for _, path in ipairs(found) do
    local bytes, read_err = fs.read(path)
    if not bytes then
      return false, corpus_failure(name, fs.basename(path), "",
        "corpus read failed: " .. tostring(read_err))
    end
    local armed = arm(budget)
    local ok, held, why = pcall(check, bytes)
    if armed then
      disarm()
    end
    if not ok or not held then
      -- No shrinking: a stored input is already minimized, and
      -- re-minimizing it would report bytes that are not the ones on
      -- disk under the name of the file that holds them.
      return false, corpus_failure(name, fs.basename(path), bytes,
        detail.detail_of(ok, held, why, budget))
    end
  end
  return true, ""
end

--- Store one failing input, when FUZZ_SAVE=1 says to.
--- Content-addressed, so re-finding the same bug rewrites the same
--- bytes at the same path instead of growing the corpus. Write errors
--- are deliberately not reported: the failure message the caller is
--- about to return is the load-bearing output, and losing a corpus
--- entry must never turn one failure into two.
--- @param name string The property name
--- @param input string The minimized failing input to store
local function save(name: string, input: string)
  if detail.env_integer("FUZZ_SAVE", 0) ~= 1 then
    return
  end
  local dir = dir_for(name)
  local made = fs.make_dirs(dir)
  if not made then
    return
  end
  local _wrote, _err = fs.write(fs.join(dir, hash.sha256_hex(input)), input)
end

local record CorpusModule
  dir_for: function(name: string): string
  replay: function(
  name: string,
  check: function(input: string): boolean, string,
  budget: integer,
  arm: function(budget: integer): boolean,
  disarm: function()
): boolean, string
save: function(name: string, input: string)
end

local M: CorpusModule = {
  dir_for = dir_for,
  replay = replay,
  save = save,
}

return M
