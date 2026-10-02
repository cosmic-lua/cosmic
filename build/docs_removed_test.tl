--- `cosmic docs` answers a name [`cosmic.removed`] lists as gone with
--- what to write instead, not with a search's nearest member: one test
--- for each shape of name it lists (a member of a module that still
--- loads, a type, a field of a removed global), and one for a name that
--- is still documented. The tree each test builds holds a member of
--- another module that shares the removed name's last words, which is
--- what the search answered before.

local docs = require("build.docs")
local fixture = require("build.docs_fixture")
local teal = require("build.teal")

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- A standard-library module `name` (`net`) that documents [`Net.unix`]
--- and nothing else; `extra` is more of its source, before its return.
local function module(name: string, record: string, extra?: string): string
  return source(
    "--- The " .. name .. " module.",
    "",
    "local record " .. record,
    "end",
    "",
    "--- A live member.",
    "function " .. record .. ".unix(path: string): string",
    "  return path",
    "end",
    "",
    extra or "",
    "return " .. record)
end

--- The tree each test queries: the library's modules under a removed
--- name, and the build's own [`build.codec`], whose [`verb.encoder`] the
--- qualifier `Codec` also names as a module's last name.
local function tree(extra?: {string: string}): {string: string}
  local files: {string: string} = {
    ["cosmic/net.tl"] = module("net", "Net"),
    ["cosmic/http.tl"] = module("http", "Http"),
    ["cosmic/codec.tl"] = module("codec", "Codec"),
    ["cosmic/env.tl"] = module("env", "Env", source(
      "--- One variable; this is the os.getenv operation.",
      "function Env.get(name: string): string | nil",
      "  return name",
      "end",
      "")),
    ["build/codec.tl"] = source(
      "--- The codec verb.",
      "",
      "local record verb",
      "end",
      "",
      "--- An incremental encoder for `name`.",
      "function verb.encoder(name: string): string",
      "  return name",
      "end",
      "",
      "return verb"),
  }
  for path, text in pairs(extra or {}) do
    files[path] = text
  end
  return files
end

--- The page `query` answers, as `cosmic docs` prints it: every entry's
--- lines in turn.
local function page(view: docs.View, found: docs.Lookup): string
  local out: {string} = {}
  for _, entry in ipairs(found) do
    for _, line in ipairs((assert(docs.render(view, entry)))) do
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

--- A member a module no longer has, by the module's last name, in
--- either case or in full, answers what replaces it, as the compiler
--- says it; `Codec.encoder` does not answer the verb's [`verb.encoder`].
local function test_a_removed_member_answers_its_replacement(dir: string)
  local view = assert(docs.view({ fixture.database(dir, tree()) }))
  for _, query in ipairs({ "Net.pair", "net.pair", "cosmic.net.pair" }) do
    local found = assert(docs.lookup(view, query))
    assert(found.exact and #found == 1 and found[1].kind == "removed", query)
    assert(found[1].module == "cosmic.net", found[1].module)
    local shown = page(view, found)
    assert(shown:find(query .. " was removed: listen at a socket file", 1, true), shown)
    assert(shown:find("Net.listen(Net.unix(path))", 1, true), shown)
    assert(not shown:find("Net.unix(path): string", 1, true), shown)
  end
  local found = assert(docs.lookup(view, "Codec.encoder"))
  assert(found.exact and #found == 1 and found[1].kind == "removed")
  local shown = page(view, found)
  assert(shown:find("Codec.encoder was removed: the streaming coders are", 1, true), shown)
  assert(not shown:find("verb.encoder", 1, true), shown)
end

--- A type a module no longer declares answers the same way, and a
--- removed member of another module (`Http.upload`) with it.
local function test_a_removed_type_answers_its_replacement(dir: string)
  local view = assert(docs.view({ fixture.database(dir, tree()) }))
  local found = assert(docs.lookup(view, "Net.Pair"))
  assert(found.exact and #found == 1 and found[1].kind == "removed")
  local shown = page(view, found)
  assert(shown:find("Net.Pair was removed: Net.pair is gone, and so its record", 1, true), shown)
  assert(not shown:find("Net.unix", 1, true), shown)
  local upload = page(view, (assert(docs.lookup(view, "Http.upload"))))
  assert(upload:find("Http.upload was removed: no caller in the tree sent a streamed", 1, true),
    upload)
  assert(not upload:find("Http.unix", 1, true), upload)
end

--- A field of a removed global (`os.getenv`) answers what
--- [`cosmic.removed`]'s `message` says of it, which a compile error and
--- a run-time failure say too, and not the function whose comment only
--- mentions the old name.
local function test_a_removed_global_s_field_answers_its_replacement(dir: string)
  local view = assert(docs.view({ fixture.database(dir, tree()) }))
  local found = assert(docs.lookup(view, "os.getenv"))
  assert(found.exact and #found == 1 and found[1].kind == "removed")
  assert(found[1].module == "cosmic.removed", found[1].module)
  local shown = page(view, found)
  assert(shown:find("os.getenv is not available: use Env.get(name)", 1, true), shown)
  assert(not shown:find("One variable", 1, true), shown)
end

--- A name that is still documented keeps its own page, though the
--- catalog lists it, and a name the catalog does not list is searched
--- as it was.
local function test_a_live_name_keeps_its_page(dir: string)
  local live = module("net", "Net", source(
    "--- Two connections that reach each other.",
    "function Net.pair(): string",
    "  return \"\"",
    "end",
    ""))
  local view = assert(docs.view({ fixture.database(dir, tree({ ["cosmic/net.tl"] = live })) }))
  local found = assert(docs.lookup(view, "Net.pair"))
  assert(found.exact and #found == 1 and found[1].kind == "function", found[1].kind)
  assert(found[1].source_symbol == "Net.pair", found[1].source_symbol)
  assert(not page(view, found):find("was removed", 1, true))
  local unlisted = assert(docs.lookup(view, "Net.unix"))
  assert(unlisted[1].kind == "function" and unlisted[1].source_symbol == "Net.unix")
  local searched = assert(docs.lookup(view, "Net.nothing_of_the_kind"))
  for _, entry in ipairs(searched) do
    assert(entry.kind ~= "removed", entry.source_symbol)
  end
end

--- The page says a member's replacement in the words the compiler's
--- hint does (build.teal's `replacement`, which reads the same catalog:
--- this test requires it through build.docs), so the sentence that is
--- spelled twice cannot drift.
local function test_the_page_says_what_the_compiler_hint_says(dir: string)
  local view = assert(docs.view({ fixture.database(dir, tree()) }))
  for _, case in ipairs({
    { "Net.pair", "invalid key 'pair' in record 'Net' of type Net", "cosmic.net" },
    { "Http.upload", "invalid key 'upload' in record 'Http' of type Http", "cosmic.http" },
    { "Net.Pair", "unknown type Net.Pair", "cosmic.net" },
  }) do
    local owner = case[1]:match("^(%a+)%.")
    local bound = "local " .. owner .. " = require(\"" .. case[3] .. "\")\nreturn " ..
      case[1] .. "\n"
    local hint = teal.replacement(case[2], bound, 2, 8)
    local found = assert(docs.lookup(view, case[1]))
    assert(hint ~= nil and found[1].text == hint,
      case[1] .. ": " .. tostring(hint) .. " ~= " .. tostring(found[1].text))
  end
end

--- A removed member is answered whether or not the view holds the module
--- it left: a project's view, or a tree, need not carry it.
local function test_a_removed_member_is_answered_without_its_module(dir: string)
  local view = assert(docs.view({ fixture.database(dir, {
    ["cosmic/codec.tl"] = module("codec", "Codec"),
  }) }))
  local found = assert(docs.lookup(view, "Net.pair"))
  assert(found.exact and #found == 1 and found[1].kind == "removed")
  assert(page(view, found):find("Net.pair was removed: listen at a socket file", 1, true))
end
