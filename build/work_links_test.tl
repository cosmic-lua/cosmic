--- The code that finds the links of the files, as a tool names it ([`build.work`]'s `links_finder`): by the tokens of
--- each module [`build.link_files`] reaches. It reads the whole projection (`o/cosmic.db`) for the binary's `boot_hash` meta row, whose presence
--- makes a stage name the code from the sources the binary carries and not from the tree's boot fingerprint.
local CodeFingerprint = require("build.code_fingerprint")
local CodeWalk = require("build.code_walk")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local work = require("build.work")

Test.policy{ grants = { { path = "core", letters = "r" }, { path = "o/cosmic.db", letters = "r" } } }

--- What a stage of an empty project at `root` leaves as [`links_by`]: the name of the code that finds links.
local function links_by(root: string): string
  assert(Fs.mkdirs(root))
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  local rows = assert(Sqlite.text_rows(handle.db, "SELECT value FROM meta WHERE key = 'links_by'"))
  assert(work.close(handle))
  local first = assert(rows[1], "a stage named no code that finds links")
  return first:text(1)
end

--- The name is the hash of each module of the walk by its name and the digest of its tokens, whether the module is as
--- the binary carries it (its source) or as a test's pure store keeps it (its tokens): the form of a module is its own
--- form, so a comment in the source never reaches the name.
local function test_the_code_that_finds_links_is_named_by_the_tokens_of_its_modules(tmp: string)
  assert(Store.meta("boot_hash") ~= nil, "the binary carries no boot hash")
  local names = assert(CodeWalk.reach(CodeWalk.links, Store.requires))
  assert(#names > 1, "the walk reaches no module")
  local by_source: mut {string} = {}
  for _, name in ipairs(names) do
    local source = assert(Store.source(name))
    by_source[#by_source + 1] = name .. "\n" .. CodeFingerprint.of(source, name)
  end
  local from_source = Hash.hex_sha256(table.concat(by_source, "\n\0\n"))
  local named = links_by(tmp .. "/project")
  assert(named == from_source, "the code that finds links is named otherwise than by the tokens of its modules")
end
