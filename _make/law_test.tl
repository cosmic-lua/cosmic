#!/usr/bin/env cosmic
-- The selection law, asked directly.
--
-- selection_test.tl drives real projects through real make, which is
-- where the law is finally true. These are the unit tests for the
-- pre-flight itself: that every verb reaches an arm of `resolve`, that
-- the whole-project verbs refuse rather than ignore, and that a verb
-- added without a way to resolve its paths cannot silently accept
-- them.

local law = require("_make.law")
local types = require("_make.types")

local type Kind = types.Kind
local type Project = types.Project
local type Verb = types.Verb

--- A project of the given kinds, one file each.
local function project_of(kinds: {Kind}): Project
  local files: {types.File} = {}
  for i, k in ipairs(kinds) do
    files[#files + 1] = {path = "f" .. i .. ".tl", kind = k}
  end
  return {root = "/p", binaries = {}, files = files}
end

--- The verb row a name would carry, for the arms that only read it.
local function verb(name: string): Verb
  return {name = name}
end

-- An empty selection is every verb's whole set, so it always resolves.
-- Including for the verbs that refuse a path: "no paths" is what they
-- are for.
local function test_no_paths_always_resolves()
  for _, name in ipairs({"clean", "ci", "build", "check", "fetch", "docs"}) do
    local ok, err = law.resolve(verb(name), project_of({"module"}), {})
    assert(ok, name .. " with no selection must resolve, got: " .. err)
  end
end
test_no_paths_always_resolves()

-- A whole-project verb REFUSES a path and says why. Ignoring one is
-- the failure this exists to close: the run succeeds, so the reader
-- learns a spelling that does something other than what it says.
local function test_whole_project_verbs_refuse_and_say_why()
  local ok, err = law.resolve(verb("clean"), project_of({"module"}), {"db"})
  assert(not ok, "clean must refuse a selection")
  assert(err:find("clean takes no paths", 1, true), "got: " .. err)
  assert(err:find(law.WHOLE["clean"], 1, true),
    "the refusal carries the reason: " .. err)

  local cok, cerr = law.resolve(verb("ci"), project_of({"module"}), {"db"})
  assert(not cok, "ci must refuse a selection")
  assert(cerr:find("whole gate", 1, true), "got: " .. cerr)
end
test_whole_project_verbs_refuse_and_say_why()

-- A path naming nothing is refused by name, whichever arm answers. The
-- three own-resolver verbs each have a different candidate set, and
-- each still complains about the path the user typed.
local function test_a_path_naming_nothing_is_refused()
  local proj = project_of({"module", "pin"})
  local cases: {string: string} = {
    check = "nothing to do under: nope",
    fetch = "nothing to do under: nope",
    docs = "nothing to do under: nope",
    build = "no binary named by: nope",
  }
  for name, want in pairs(cases) do
    local ok, err = law.resolve(verb(name), proj, {"nope"})
    assert(not ok, name .. " must refuse a path that names nothing")
    assert(err:find(want, 1, true),
      name .. " should say '" .. want .. "', got: " .. err)
  end
end
test_a_path_naming_nothing_is_refused()

-- A verb with no whole-project reason, no resolver and no Selection
-- cannot have its paths checked -- so it does not get to accept them.
-- The fallback is a refusal, which is what makes adding a verb without
-- a selection rule a loud omission rather than an unchecked one.
local function test_an_unknown_verb_shape_refuses_paths()
  local ok, err = law.resolve(verb("nosuch"), project_of({"module"}), {"db"})
  assert(not ok, "a verb with no selection rule must refuse paths")
  assert(err:find("nosuch takes no paths", 1, true), "got: " .. err)
end
test_an_unknown_verb_shape_refuses_paths()

print("all law tests passed")
