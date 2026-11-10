--- The memo of [`build.check_memo`]: rows survive being written as text, a key
--- moves with the salt, the dialect and the bytes, and a run keeps the rows it
--- used.
local Array = require("cosmic.array")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local check_memo = require("build.check_memo")

local function test_rows_with_tabs_breaks_and_backslashes_come_back_as_written()
  local rows: {{string}} = {
    { "E", "a\tb", "c\nd", "e\\f", "" },
    { "H", "", "x\r\ny", "\\t", "\\" },
  }
  local back = check_memo.decode(check_memo.encode(rows))
  assert(#back == 2 and #back[1] == 5 and #back[2] == 5, #back)
  for i, row in ipairs(rows) do
    for j, field in ipairs(row) do
      assert(Array.at(Array.at(back, i), j) == field, tostring(i) .. "," .. tostring(j))
    end
  end
  assert(#check_memo.decode("") == 0)
end

local function test_a_key_moves_with_the_salt_the_dialect_and_the_bytes()
  local base = check_memo.key("salt", "tl", "bytes")
  assert(base == check_memo.key("salt", "tl", "bytes"))
  assert(base ~= check_memo.key("other", "tl", "bytes"))
  assert(base ~= check_memo.key("salt", "decl", "bytes"))
  assert(base ~= check_memo.key("salt", "tl", "byte"))
end

local function test_a_run_keeps_the_rows_it_used_and_drops_the_rest()
  local db = assert(Sqlite.memory())
  assert(check_memo.prepare(db, "k"))
  check_memo.put(db, "k", "one", "1")
  check_memo.put(db, "k", "two", "2")
  check_memo.put(db, "other", "one", "x")
  assert(check_memo.get(db, "k", "one") == "1" and check_memo.get(db, "k", "none") == nil)
  check_memo.finish(db, "k")
  assert(check_memo.get(db, "k", "two") == "2")
  -- A second run that uses only `one`: `two` goes.
  assert(check_memo.prepare(db, "k"))
  assert(check_memo.get(db, "k", "one") == "1")
  check_memo.finish(db, "k")
  assert(check_memo.get(db, "k", "two") == nil and check_memo.get(db, "other", "one") == "x")
  assert(db:close())
end

--- What one checkout's run wrote or used, a fresh checkout's run takes from the file they share and keeps in its own
--- memo, where it stands with the shared file gone. A checkout whose checking code is another's takes none of it, nor
--- does any take a row of a kind whose key names the checkout.
local function test_a_row_one_checkout_wrote_stands_in_another_of_the_same_code(tmp: string)
  local path = tmp .. "/checks.db"
  assert(check_memo.share(path, { code = "a" }))
  local first = assert(Sqlite.memory())
  assert(check_memo.prepare(first, "k"))
  check_memo.put(first, "k", "one", "1")
  check_memo.put(first, "other", "one", "x")
  check_memo.finish(first, "k")
  assert(check_memo.prepare(first, "c"))
  check_memo.put(first, "c", "one", "here")
  check_memo.finish(first, "c")
  -- Neither written there, nor taken where the file holds one.
  local file = assert(Sqlite.open(path, { writable = true }))
  local written = assert(assert(Sqlite.text_rows(file, "SELECT count(*) FROM check_memo_v1 WHERE kind = 'c'"))[1])
  assert(written:text(1) == "0", "a row whose key names its checkout was written to the shared file")
  assert(Sqlite.run(file, "INSERT INTO check_memo_v1 (code, kind, key, value, used_ns) VALUES ('a', 'c', 'two', 'x', 1)"))
  assert(file:close())
  local second = assert(Sqlite.memory())
  assert(check_memo.prepare(second, "k"))
  assert(check_memo.get(second, "k", "one") == "1", "a sibling's row was not taken")
  assert(check_memo.get(second, "k", "none") == nil)
  -- A kind is shared as it finishes: `other` never did.
  assert(check_memo.get(second, "other", "one") == nil, "a row of a kind that did not finish was shared")
  assert(check_memo.get(second, "c", "two") == nil, "a row whose key names its checkout was taken")
  check_memo.finish(second, "k")
  assert(not check_memo.share(nil))
  assert(check_memo.prepare(second, "k"))
  assert(check_memo.get(second, "k", "one") == "1", "the row taken was not kept in the checkout's own memo")
  check_memo.finish(second, "k")
  local third = assert(Sqlite.memory())
  assert(check_memo.prepare(third, "k"))
  assert(check_memo.get(third, "k", "one") == nil, "a run that shares none took a row")
  check_memo.finish(third, "k")
  -- Another code's checkout: the row is not its to stand on, and what it writes under the key is its own.
  assert(check_memo.share(path, { code = "b" }))
  local other = assert(Sqlite.memory())
  assert(check_memo.prepare(other, "k"))
  assert(check_memo.get(other, "k", "one") == nil, "a row stood under code that did not earn it")
  check_memo.put(other, "k", "one", "2")
  check_memo.finish(other, "k")
  assert(check_memo.share(path, { code = "a" }))
  local back = assert(Sqlite.memory())
  assert(check_memo.prepare(back, "k"))
  assert(check_memo.get(back, "k", "one") == "1", "another code's write replaced the row")
  check_memo.finish(back, "k")
  assert(not check_memo.share(nil))
  assert(first:close() and second:close() and third:close() and other:close() and back:close())
end

--- A row a checkout answers from its own memo is not written to the shared file: the tool that made it may have been
--- of other code than the one the file would hold it under. A row it took from the file is, and stays there.
local function test_a_row_answered_by_the_checkouts_own_memo_is_not_shared(tmp: string)
  local own = assert(Sqlite.memory())
  assert(not check_memo.share(nil))
  assert(check_memo.prepare(own, "k"))
  check_memo.put(own, "k", "one", "1")
  check_memo.finish(own, "k")
  assert(check_memo.share(tmp .. "/checks.db", { code = "a" }))
  assert(check_memo.prepare(own, "k"))
  assert(check_memo.get(own, "k", "one") == "1")
  check_memo.put(own, "k", "two", "2")
  check_memo.finish(own, "k")
  local fresh = assert(Sqlite.memory())
  assert(check_memo.prepare(fresh, "k"))
  assert(check_memo.get(fresh, "k", "one") == nil, "a row another tool may have made was shared under this one's code")
  assert(check_memo.get(fresh, "k", "two") == "2")
  check_memo.finish(fresh, "k")
  assert(not check_memo.share(nil))
  assert(own:close() and fresh:close())
end

--- One run of a checkout that shares its rows through `path` at the time `now`, keeping `kept_bytes`: the keys of
--- `took` it found, having written `wrote`, each with a value of `size` bytes.
local function shared_run(path: string, now: integer, wrote: {string}, took: {string}, kept_bytes?: integer,
                          size?: integer): {string:boolean}
  assert(check_memo.share(path, { code = "a", kept_bytes = kept_bytes }))
  local db = assert(Sqlite.memory())
  assert(check_memo.prepare(db, "k"))
  local found: mut {string:boolean} = {}
  for _, key in ipairs(took) do found[key] = check_memo.get(db, "k", key) ~= nil end
  for _, key in ipairs(wrote) do check_memo.put(db, "k", key, string.rep("v", size or 1)) end
  check_memo.finish(db, "k", now)
  assert(db:close())
  return found
end

local day <const> = 24 * 3600 * 1000000000

--- A shared row no run has used for thirty days goes when a run next settles; one used since stays.
local function test_a_shared_row_unused_for_thirty_days_goes(tmp: string)
  local path = tmp .. "/checks.db"
  local _ = shared_run(path, 1 * day, { "old", "kept" }, {})
  local taken = shared_run(path, 20 * day, {}, { "kept" })
  assert(taken["kept"] == true)
  local _ = shared_run(path, 40 * day, { "new" }, {})
  local left = shared_run(path, 41 * day, {}, { "old", "kept", "new" })
  assert(left["old"] == false, "a row unused for thirty days stayed")
  assert(left["kept"] == true and left["new"] == true, "a row used within thirty days went")
  assert(not check_memo.share(nil))
end

--- Past the bytes kept, the rows least lately used go first.
local function test_past_the_bytes_kept_the_least_lately_used_go(tmp: string)
  local path = tmp .. "/checks.db"
  local _ = shared_run(path, 1 * day, { "first" }, {}, 5000, 2000)
  local _ = shared_run(path, 2 * day, { "second" }, {}, 5000, 2000)
  local both = shared_run(path, 3 * day, {}, { "second" }, 5000)
  assert(both["second"] == true)
  -- A third row of 2000 bytes is past 5000 with the two before it: the one used longest ago goes.
  local _ = shared_run(path, 4 * day, { "third" }, {}, 5000, 2000)
  local left = shared_run(path, 5 * day, {}, { "first", "second", "third" }, 1000000)
  assert(left["first"] == false, "the row least lately used stayed past the bytes kept")
  assert(left["second"] == true and left["third"] == true, "a row used later went first")
  assert(not check_memo.share(nil))
end

--- Rows are shared only at the default place: a run told where its compiles are, or to share none, shares no rows.
local function test_rows_are_shared_only_where_the_build_cache_is_the_default(tmp: string)
  assert(check_memo.shared_path({ COSMIC_BUILD_CACHE = "0", HOME = tmp }) == nil)
  assert(check_memo.shared_path({ COSMIC_BUILD_CACHE = tmp .. "/cache.db", HOME = tmp }) == nil)
  assert(check_memo.shared_path({ XDG_CACHE_HOME = tmp .. "/cache" }) == tmp .. "/cache/cosmic/build/checks.db")
  assert(check_memo.shared_path({}) == nil, "a run with no cache directory shares none")
end

--- A shared file that cannot be opened, or is not this user's alone to write, or is a link, is done without: the
--- checkout's own memo answers as it did.
local function test_a_shared_file_that_cannot_be_trusted_is_done_without(tmp: string)
  local opened, why = check_memo.share(tmp .. "/none/checks.db", { code = "a" })
  assert(not opened and why ~= "", "a file in no directory was opened")
  assert(Fs.write(tmp .. "/open.db", "", 0x1b6))
  assert(sys.chmod(tmp .. "/open.db", 0x1b6))
  opened, why = check_memo.share(tmp .. "/open.db", { code = "a" })
  assert(not opened and why:find("writable by its group or others", 1, true) ~= nil, why)
  assert(Fs.write(tmp .. "/group.db", "", 0x1b4))
  assert(sys.chmod(tmp .. "/group.db", 0x1b4))
  opened, why = check_memo.share(tmp .. "/group.db", { code = "a" })
  assert(not opened and why:find("writable by its group or others", 1, true) ~= nil, why)
  assert(check_memo.share(tmp .. "/real.db", { code = "a" }))
  assert(not check_memo.share(nil))
  assert(sys.symlink(tmp .. "/real.db", tmp .. "/link.db"))
  opened, why = check_memo.share(tmp .. "/link.db", { code = "a" })
  assert(not opened and why:find("a symbolic link", 1, true) ~= nil, why)
  local db = assert(Sqlite.memory())
  assert(check_memo.prepare(db, "k"))
  check_memo.put(db, "k", "one", "1")
  assert(check_memo.get(db, "k", "one") == "1" and check_memo.get(db, "k", "none") == nil)
  check_memo.finish(db, "k")
  assert(db:close())
end

--- The code a shared row is held under is the bytecode of every module [`build.fix`] reaches and the core: an edit to
--- a module it reaches through another moves it, one to a module it does not reach leaves it, and a tool that holds
--- a module it cannot read the bytecode of names none.
local function test_the_code_a_shared_row_is_held_under_is_the_closure_of_fix_and_the_core()
  local function coded(edited: string?, image: string, unread?: string): string?, string
    local graph: {string:{string}} = { ["build.fix"] = { "build.tree_checks", "cosmic.sys" },
      ["build.tree_checks"] = { "lang.check" }, ["lang.check"] = { "lang.generics" }, ["lang.generics"] = {},
      ["build.test"] = { "lang.check" } }
    return check_memo.code_of({
      requires = function(name: string): {string}?, string return graph[name] or {}, "" end,
      bytecode = function(name: string): string?, string
        if graph[name] == nil then return nil, "no module '" .. name .. "' in the binary" end
        if name == unread then return nil, "its bytecode does not inflate" end
        return "the bytecode of " .. name .. (if name == edited then ", edited" else "" end), ""
      end,
      holds = function(name: string): boolean?, string return graph[name] ~= nil, "" end,
      core = image,
    })
  end
  local base = assert(coded(nil, "core"))
  assert(#base == 64 and base == coded(nil, "core"))
  assert(base ~= coded("lang.generics", "core"), "an edit to a module fix reaches through others left the code as it was")
  assert(base == coded("build.test", "core"), "an edit to a module fix does not reach moved the code")
  assert(base ~= coded(nil, "another core"), "another core left the code as it was")
  local none, why = coded(nil, "core", "lang.check")
  assert(none == nil and why == "lang.check: its bytecode does not inflate", why)
end
