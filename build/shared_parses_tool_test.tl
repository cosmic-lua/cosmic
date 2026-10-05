--- The cases of build/shared_parses_test.tl that build checkouts of a
--- project end to end: a parse one checkout made stands in another
--- checkout of the same content, through the cache `COSMIC_BUILD_CACHE`
--- names, and lands there as the parse would have, a doc's lines mapped
--- or not as the source's origin says; an edit parses only what it
--- edited; and a damaged row is parsed again and replaced. They declare
--- `tool` because they start this program.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local parses_fixture = require("build.parses_fixture")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local String = require("cosmic.string")
local Clock = require("cosmic.clock")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" } }

--- Every row `sql` answers of the database at `path`, a line each, and
--- every row of every parse table of a working database.
local dump = parses_fixture.dump
local parse_rows = parses_fixture.rows

--- The project every case builds: `a` requires `b`, which requires
--- `c`; `c` documents a record and its field, `b` reads that field, and
--- the guide is extracted to a test module whose example's line is the
--- guide's own ([`build.derivation`]'s `origin_lines`).
local project: {string:string} = {
  ["c.tl"] = [[
--- Boxes.
local record c
  --- A box.
  record Box
    --- What it holds.
    value: integer
  end
end

--- A box of `value`.
function c.new(value: integer): c.Box
  return { value = value }
end

return c
]],
  ["b.tl"] = [[
local c = require("c")

local record b end

--- Twice `value`, by way of a box.
function b.twice(value: integer): integer
  local box = c.new(value)
  return box.value * 2
end

return b
]],
  ["a.tl"] = [[
local b = require("b")

local record a end

function a.four(): integer
  return b.twice(2)
end

return a
]],
  ["doc/guides/guide.md"] = [[
# guide

An example the build compiles and never runs, having no output.

```teal
print(42)
```
]],
}

--- A checkout of the project at `root`, with `changed` written over it
--- (a file to "" is left out).
local function checkout(root: string, changed?: {string:string})
  local files: {string:string} = {}
  for name, source in pairs(project) do files[name] = source end
  for name, source in pairs(changed or {}) do files[name] = source end
  for name, source in pairs(files) do
    if source ~= "" then
      assert(Fs.mkdirs(Fs.dirname(root .. "/" .. name)))
      assert(Fs.write(root .. "/" .. name, source))
    end
  end
end

--- Builds the checkout at `root` (`cosmic test`, which has nothing to
--- run), answering what it printed.
local function build(root: string, env: {string:string}): string
  local output = root .. ".out"
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(60),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil and result.ok, tostring(trouble) .. text)
  return text
end

--- The environment the builds of a case run in, sharing through a
--- cache in `tmp`, and where that cache is.
local function environment(tmp: string): {string:string}, string
  local env = this_program.environment()
  local path = tmp .. "/cache/cache.db"
  env.COSMIC_BUILD_CACHE = path
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  -- It runs no test, so it sandboxes none: the same on every host.
  env.COSMIC_TEST_SANDBOX = "0"
  return env, path
end

--- Builds `root` and checks its build line says `wanted`.
local function built_as(root: string, env: {string:string}, wanted: string): string
  local text = build(root, env)
  assert(text:find(wanted, 1, true), wanted .. "\n" .. text)
  return text
end

--- `parse_rows` of the checkout at `root`.
local function parse_rows_of(root: string): string
  local db = assert(Sqlite.open(root .. "/o/build.db"))
  local out = parse_rows(db)
  assert(db:close())
  return out
end

--- The line `cosmic docs` gives `symbol` of the checkout at `root`.
local function doc_line(root: string, symbol: string): string
  return dump(root .. "/o/build.db", "SELECT d.line FROM docs d JOIN inputs i " ..
      "ON i.source_hash = d.source_hash WHERE d.symbol = '" .. symbol .. "'")
end

local function test_a_second_checkout_parses_nothing_the_first_parsed(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env = environment(tmp)
  checkout(tmp .. "/first")
  built_as(tmp .. "/first", env, "(4 compiled, 0 cached; 4 sources parsed;")
  checkout(tmp .. "/second")
  built_as(tmp .. "/second", env, "(0 compiled, 4 cached, 4 of them taken from another " ..
      "checkout; 0 sources parsed, 4 taken from another checkout;")
  -- What each checkout keeps of a parse, and what its projection makes
  -- of it -- docs, uses, the catalog, examples, tests -- are the same.
  local first, second = parse_rows_of(tmp .. "/first"), parse_rows_of(tmp .. "/second")
  assert(first:find("docs 0", 1, true) == nil and first == second, first .. "\n--\n" .. second)
  local projection: {string} = {
    "SELECT path, file, kind, hex(source_hash), hex(key), tests FROM modules ORDER BY path",
    "SELECT * FROM docs ORDER BY 1, 2, 3",
    "SELECT * FROM uses ORDER BY 1, 2, 3, 4, 5",
    "SELECT * FROM catalog ORDER BY 1, 2, 3",
    "SELECT * FROM examples ORDER BY 1, 2, 3",
    "SELECT * FROM imports ORDER BY 1, 2",
  }
  for _, query in ipairs(projection) do
    local one = dump(tmp .. "/first/o/cosmic.db", query)
    local other = dump(tmp .. "/second/o/cosmic.db", query)
    assert(one == other, query .. "\n" .. one .. "\n--\n" .. other)
  end
  assert(dump(tmp .. "/second/o/cosmic.db", "SELECT count(*) FROM docs") ~= "0")
  -- The guide's example is at its line in the guide.
  assert(doc_line(tmp .. "/second", "example_1") == "5", doc_line(tmp .. "/second", "example_1"))
  -- Its own now: a build again takes nothing, and parses nothing.
  local again = built_as(tmp .. "/second", env, "(0 compiled, 4 cached;")
  assert(not again:find("another checkout", 1, true) and not again:find("parsed", 1, true), again)
end

local function test_an_edit_parses_only_what_it_edited(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env = environment(tmp)
  checkout(tmp .. "/first")
  built_as(tmp .. "/first", env, "4 sources parsed;")
  checkout(tmp .. "/edited", { ["c.tl"] = project["c.tl"] .. "-- edited\n" })
  built_as(tmp .. "/edited", env, "; 1 source parsed, 3 taken from another checkout;")
end

--- The same source parsed from a doc and from the tree is two parses:
--- a doc's lines are mapped to the doc, a tree file's are its own.
local function test_a_mapped_parse_stands_only_for_a_mapped_one(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env, path = environment(tmp)
  checkout(tmp .. "/doc")
  built_as(tmp .. "/doc", env, "4 sources parsed;")
  local generated = dump(tmp .. "/doc/o/build.db",
    "SELECT source FROM derived WHERE file = 'doc/guides/guide.md'")
  local own_line = 0
  local number = 0
  for line in String.lines(generated) do
    number = number + 1
    if line:find("^local function example_1") then own_line = number end
  end
  assert(own_line > 0 and own_line ~= 5, generated)
  -- The generated source as a file of the tree, the guide gone: the
  -- same source, parsed again, as its own lines stand; the rest taken.
  local plain = { ["doc/guides/guide.md"] = "", ["guide_test.tl"] = generated }
  checkout(tmp .. "/plain", plain)
  built_as(tmp .. "/plain", env, "; 1 source parsed, 3 taken from another checkout;")
  assert(doc_line(tmp .. "/plain", "example_1") == tostring(own_line),
    doc_line(tmp .. "/plain", "example_1") .. " " .. own_line)
  local rows = dump(path, "SELECT mapped, count(*) FROM parsed_v1 GROUP BY mapped ORDER BY mapped")
  assert(rows == "0\t4\n1\t1", rows)
  -- Each stands for its own.
  checkout(tmp .. "/plain_again", plain)
  built_as(tmp .. "/plain_again", env, "; 0 sources parsed, 4 taken from another checkout;")
  assert(doc_line(tmp .. "/plain_again", "example_1") == tostring(own_line))
  checkout(tmp .. "/doc_again")
  built_as(tmp .. "/doc_again", env, "; 0 sources parsed, 4 taken from another checkout;")
  assert(doc_line(tmp .. "/doc_again", "example_1") == "5")
end

--- A row that does not decode to what its digest says is a miss: the
--- source is parsed, the rest are still taken, and the row is replaced.
local function test_a_damaged_parse_is_parsed_again_and_replaced(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env, path = environment(tmp)
  checkout(tmp .. "/first")
  built_as(tmp .. "/first", env, "4 sources parsed;")
  local c_hash = dump(tmp .. "/first/o/build.db", "SELECT source_hash FROM inputs WHERE path = 'c'")
  local b_hash = dump(tmp .. "/first/o/build.db", "SELECT source_hash FROM inputs WHERE path = 'b'")
  local cache = assert(Sqlite.open(path, { writable = true }))
  -- `b`'s rows become `c`'s, and `c`'s become no stream at all.
  assert(Sqlite.run(cache, "UPDATE parsed_v1 SET rows = (SELECT rows FROM parsed_v1 " ..
      "WHERE source_hash = ?2) WHERE source_hash = ?1", { { text = b_hash }, { text = c_hash } }))
  assert(Sqlite.run(cache, "UPDATE parsed_v1 SET rows = x'deadbeef' WHERE source_hash = ?1",
    { { text = c_hash } }))
  assert(cache:close())
  checkout(tmp .. "/second")
  local second = built_as(tmp .. "/second", env, "; 2 sources parsed, 2 taken from another checkout;")
  assert(not second:find("shared compiles: ", 1, true), second)
  assert(parse_rows_of(tmp .. "/first") == parse_rows_of(tmp .. "/second"))
  checkout(tmp .. "/third")
  built_as(tmp .. "/third", env, "; 0 sources parsed, 4 taken from another checkout;")
end

local function test_the_cache_turned_off_shares_no_parse(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env = environment(tmp)
  env.COSMIC_BUILD_CACHE = "0"
  checkout(tmp .. "/first")
  built_as(tmp .. "/first", env, "(4 compiled, 0 cached; 4 sources parsed;")
  checkout(tmp .. "/second")
  built_as(tmp .. "/second", env, "(4 compiled, 0 cached; 4 sources parsed;")
  assert(Fs.stat(tmp .. "/cache") == nil, "a cache turned off was written")
end
