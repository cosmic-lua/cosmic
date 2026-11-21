--- What [`c.check`] makes of clang's static analyzer over the files it is told to analyze (`cosmic fix` names the
--- core's own): a finding fails the file with its line, a clean file passes, and the memo keeps only a pass.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local c = require("build.c")

--- The pinned zig, which a check starts itself where it is installed, and the headers the core's C is read with.
Test.policy{
  grants = {
    { path = "bin/zig.pin", letters = "r" },
    { path = "ci/cosmic-driver.pin", letters = "r" },
    { path = "core/", letters = "r" },
    { path = "vendor/bzip2/", letters = "r" },
    { path = "vendor/cares/include/", letters = "r" },
    { path = "vendor/curl/include/", letters = "r" },
    { path = "vendor/expat/lib/", letters = "r" },
    { path = "vendor/lua/src/", letters = "r" },
    { path = "vendor/mbedtls/include/", letters = "r" },
    { path = "vendor/mbedtls/tf-psa-crypto/", letters = "r" },
    { path = "vendor/miniz/", letters = "r" },
    { path = "vendor/sqlite/", letters = "r" },
    { path = "vendor/xz/src/liblzma/api/", letters = "r" },
    { path = "vendor/yyjson/src/", letters = "r" },
    { path = "/cache/zig", letters = "rwxc" },
  },
  env = { "COSMIC_BOOTSTRAP", "COSMIC_ZIG" },
  requires = { "pinned_zig" },
}

local root = assert(Fs.absolute("."))

local dereferenced = [[
int probe(int x);
int probe(int x) {
  int *p = 0;
  if (x > 1) return 0;
  return *p;
}
]]

local guarded = [[
int probe(int x);
int probe(int x) {
  int value = 0;
  int *p = &value;
  if (x > 1) return 0;
  return *p;
}
]]

--- The analyzer's findings of `case.c` under `tmp`, each as `line rule`, with outcomes kept in `store`.
local function analyzed(tmp: string, store: Sqlite.Handle): {string}
  local outcome = assert(c.check(root, { "case.c" }, tmp, nil, store, { ["case.c"] = true })[1])
  local found = outcome.findings
  assert(found ~= nil, outcome.trouble)
  local out: mut {string} = {}
  for _, f in ipairs(found) do
    if f.rule == "analyzer" then out[#out + 1] = tostring(f.line) .. " " .. f.message end
  end
  return out
end

local function test_the_analyzer_fails_a_null_dereference_and_passes_its_fix(tmp: string)
  local store = assert(Sqlite.open(":memory:", { writable = true }))
  assert(Fs.write(tmp .. "/case.c", dereferenced))
  local first = analyzed(tmp, store)
  assert(#first == 1 and first[1]:find("^5 Dereference of null pointer") ~= nil, table.concat(first, "\n"))
  -- A finding is never kept, so the same text is analyzed again and found again.
  assert(table.concat(analyzed(tmp, store), "\n") == table.concat(first, "\n"))
  assert(Fs.write(tmp .. "/case.c", guarded))
  local after = analyzed(tmp, store)
  assert(#after == 0, table.concat(after, "\n"))
  -- No file but those it names is analyzed.
  assert(Fs.write(tmp .. "/case.c", dereferenced))
  local outcome = assert(c.check(root, { "case.c" }, tmp, nil, store)[1])
  for _, f in ipairs((assert(outcome.findings, outcome.trouble))) do
    assert(f.rule ~= "analyzer", f.message)
  end
end
