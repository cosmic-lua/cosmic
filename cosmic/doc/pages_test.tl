#!/usr/bin/env cosmic
-- The prose pages `--docs` serves: four kinds, each a directory the
-- binary ships, addressed as `<kind>.<topic>`. These run the built
-- binary, because the pages reach a reader only through it.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local cenv = require("cosmic.env")
local child = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")

-- drop LUA_PATH so the test exercises the bundled pages, not the repo
local function clean_env(): {string}
  return cenv.list({drop = {"LUA_PATH", "LUA_CPATH"}})
end

--- `cosmic --docs <query>`: whether it succeeded, and everything it said.
local function docs(query: string): boolean, string
  local r = check.must(child.run({cosmic, "--docs", query}, {env = clean_env()}))
  return r.ok, (r.stdout or "") .. (r.stderr or "")
end

local function test_each_kind_lists_its_pages()
  for _, kind in ipairs({"tutorial", "howto", "reference", "explanation"}) do
    local ok, out = docs(kind)
    assert(ok, "cosmic --docs " .. kind .. " should succeed: " .. out)
    assert(out:find("cosmic --docs " .. kind .. ".<name>", 1, true),
      kind .. " listing should say how to read one page, got: " .. out)
  end
  local _ok, out = docs("howto")
  assert(out:find("\n  test ", 1, true), "howto listing should carry the test page: " .. out)
end

local function test_a_page_is_its_markdown()
  local ok, out = docs("tutorial.quickstart")
  assert(ok, "tutorial.quickstart should resolve: " .. out)
  assert(out:find("cmd/greet/main.tl", 1, true), "the quickstart lays out a binary")
  assert(out:find("--make build", 1, true), "the quickstart builds the project")
  assert(out:find("--make ci", 1, true), "the quickstart runs the gate")
end

local function test_lint_reference_names_every_rule()
  local ok, out = docs("reference.lint")
  assert(ok, "reference.lint should resolve: " .. out)
  for _, rule in ipairs({"cast-justify", "call-after-define", "find-needle",
      "fallible-returns", "doc-citation"}) do
    assert(out:find(rule, 1, true), "reference.lint should document " .. rule)
  end
end

-- An unknown topic fails by name and lists the pages of that kind that
-- do exist, so the miss is also the directory.
local function test_an_unknown_page_lists_the_kind()
  local ok, out = docs("howto.nope")
  assert(not ok, "howto.nope should not resolve")
  assert(out:find("unknown howto 'nope'", 1, true), "the miss names the topic: " .. out)
  assert(out:find("\n  test\n", 1, true), "the miss lists the how-to pages: " .. out)
end

-- The old flat `guide.<topic>` address is gone, not aliased: one page,
-- one address, and the kind is part of it. A bare `guide` still falls
-- through to the fuzzy search like any other word, so the assertion is
-- on the dotted form and on the old index no longer being served.
local function test_guide_is_retired()
  local ok, _out = docs("guide.quickstart")
  assert(not ok, "guide.quickstart should no longer resolve")
  local _ok2, out2 = docs("guide")
  assert(not out2:find("Detailed Guides", 1, true),
    "the old guide index should not be served: " .. out2)
end

local function test_the_module_list_points_at_the_kinds()
  local ok, out = docs("")
  assert(ok, "bare --docs should succeed")
  assert(out:find("--docs tutorial", 1, true),
    "the module list should say where the prose pages are: " .. out)
end

-- The lookups behind the flag, in process: the runner this test runs
-- under carries the same four directories the binary ships.
local pages = require("cosmic.doc.pages")

local function test_kinds_are_the_four_in_order()
  check.equal(table.concat(pages.KINDS, " "), "tutorial howto reference explanation", "kinds")
  assert(pages.is_kind("howto") and not pages.is_kind("guide"), "is_kind")
  check.equal(pages.kind_title("howto"), "how-to guides", "title")
  check.equal(pages.kind_title("other"), "other", "an unknown kind titles itself")
end

local function test_pages_pair_topic_with_heading()
  local listed = pages.pages("tutorial")
  assert(#listed >= 2, "at least the two tutorials")
  local found = false
  for _, entry in ipairs(listed) do
    if entry[1] == "quickstart" then
      found = true
      assert(entry[2] ~= "quickstart", "the title comes from the H1, not the file name")
    end
  end
  assert(found, "quickstart is listed")
end

local function test_page_listing_and_miss_in_process()
  local listing = check.must(pages.page("reference", ""))
  assert(listing:find("# reference", 1, true), listing)
  assert(listing:find("\n  lint ", 1, true), "lint is listed: " .. listing)
  local body = check.must(pages.page("reference", "lint"))
  assert(body:find("cast-justify", 1, true), "the page is its markdown")
  local missing, err = pages.page("reference", "nope")
  assert(missing == nil and err:find("unknown reference 'nope'", 1, true), tostring(err))
  assert(err:find("Available reference:", 1, true), err)
  check.equal(#pages.pages("nokind"), 0, "an unknown kind has no pages")
end
