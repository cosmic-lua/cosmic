--- The tests of [`build.fingerprints`]: the digests of the modules the identities of the code hash, kept where the
--- source is first held so that no process that names the code lexes it.
local Array = require("cosmic.array")
local CodeFingerprint = require("build.code_fingerprint")
local CodeWalk = require("build.code_walk")
local Fingerprints = require("build.fingerprints")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local work = require("build.work")

Test.policy{ store_text = true }

--- Every module some walk reaches in the binary running the test, which holds the sources the tool was written from.
local function walked_names(): {string}
  local edges: mut {string:{string}} = {}
  local seen: mut {string:boolean} = {}
  local stack: mut {string} = {}
  for _, word in ipairs(CodeWalk.walks) do
    for _, root in ipairs(CodeWalk.roots_of(word)) do stack[#stack + 1] = root end
  end
  while #stack > 0 do
    local name = assert(table.remove(stack))
    if seen[name] ~= true then
      seen[name] = true
      local required = assert(Store.requires(name))
      edges[name] = required
      for _, next_name in ipairs(required) do stack[#stack + 1] = next_name end
    end
  end
  local out: mut {string} = {}
  for name in pairs(CodeWalk.walked(edges)) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- The digest the binary carries of a module is exactly that of its source, so a process that reads it names the code as
--- one that lexes the source does. This is what holds the stored digests to the sources: a writer that kept any other
--- would fail here.
local function test_the_digest_the_binary_carries_is_that_of_its_source()
  local checked = 0
  for _, name in ipairs(walked_names()) do
    local source, _ = Store.source(name)
    if source ~= nil then
      local carried, trouble = Fingerprints.carried(name)
      assert(carried ~= nil, name .. ": " .. trouble)
      assert(carried == CodeFingerprint.of(source, name), name .. ": the carried digest is not that of its source")
      checked = checked + 1
    end
  end
  assert(checked >= 5, "the walks reach " .. tostring(checked) .. " modules the binary holds")
end

--- A name the binary holds no source of has no digest, and is no error.
local function test_a_module_the_binary_does_not_hold_has_no_digest()
  local carried, trouble = Fingerprints.carried("no.such.module")
  assert(carried == nil and trouble == "", tostring(trouble))
end

--- The staged side makes a digest of a source once and keeps it by the source's hash and the form's version: it is that of
--- the source, moves with a token and not with a comment, and a declaration's is read ahead of a module's.
local function test_a_staged_source_is_digested_once_and_kept(tmp: string)
  local root = tmp .. "/staged"
  local function write(path: string, text: string)
    assert(Fs.mkdirs(Fs.dirname(root .. "/" .. path)))
    assert(Fs.write(root .. "/" .. path, text))
  end
  write("build/one.tl", "local x = 1\nreturn x\n")
  write("build/two.tl", "return 2\n")
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  local db = handle.db
  local first = assert(Fingerprints.staged(db, "build.one"))
  assert(first == CodeFingerprint.of("local x = 1\nreturn x\n", "build.one"))
  local function digested(): string
    local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM fingerprinted"))
    return Array.at(rows, 1):text(1)
  end
  assert(digested() == "1", "one source was digested")
  assert(Fingerprints.staged(db, "build.one") == first)
  assert(digested() == "1", "a source was digested again")
  local none, why = Fingerprints.staged(db, "build.absent")
  assert(none == nil and why == "", tostring(why))
  write("build/one.tl", "-- edited\nlocal x = 1\n\nreturn x\n")
  assert(work.stage(handle, { own = false }))
  assert(Fingerprints.staged(db, "build.one") == first, "a comment moved the digest")
  write("build/one.tl", "local x = 2\nreturn x\n")
  assert(work.stage(handle, { own = false }))
  assert(Fingerprints.staged(db, "build.one") ~= first, "a token left the digest")
  local lines = assert(Fingerprints.staged_lines(db, { "build.two", "build.one", "build.absent" }))
  assert(#lines == 2 and lines[1]:sub(1, 10) == "build.one " and lines[2]:sub(1, 10) == "build.two ", table.concat(lines, "|"))
  work.close(handle)
end
