local check = require("cosmic.check")
local fs = require("cosmic.fs")
local modules = require("_cli.build.modules")
local project = require("_make.project")

local tmp = os.getenv("TEST_TMPDIR") or "/tmp"

-- The manifest's whole job is the inverse of the graph's layout rule.
-- Both directions of it, because only the pair is evidence: a built
-- path maps back to the import that produced it, and anything that is
-- not one maps to nothing rather than to a plausible wrong answer.
local function test_import_path_inverts_the_layout_rule()
  assert(modules.import_path("o/pkg/db.lua", "o") == "pkg.db")
  assert(modules.import_path("o/pkg/init.lua", "o") == "pkg",
    "an init is its package, the same way init.tl is")
  assert(modules.import_path("o/x.lua", "o") == "x")
  assert(modules.import_path("o/a/b/c.lua", "o") == "a.b.c")
end
test_import_path_inverts_the_layout_rule()

local function test_import_path_refuses_what_is_not_one()
  assert(modules.import_path("pkg/db.lua", "o") == nil,
    "outside the build directory is not a built module")
  assert(modules.import_path("o/pkg/db.tl", "o") == nil,
    "a source is not a built module")
  assert(modules.import_path("o/x.tl.test.got", "o") == nil,
    "and neither is the graph's own bookkeeping")
end
test_import_path_refuses_what_is_not_one()

-- The reader is the bootstrap and requires nothing, so the manifest has
-- to say everything it needs: where the root is, what the build
-- directory is called, and one line per module.
local function test_render_names_root_build_and_modules()
  local text = modules.render("/r", {"o/a.lua", "o/b/init.lua"}, "o")
  assert(text:find("root /r\n", 1, true), "got: " .. text)
  assert(text:find("build o\n", 1, true), "got: " .. text)
  assert(text:find("mod a /r/o/a.lua\n", 1, true), "got: " .. text)
  assert(text:find("mod b /r/o/b/init.lua\n", 1, true), "got: " .. text)
end
test_render_names_root_build_and_modules()

-- Sorted, so the bytes are a function of the closure and not of the
-- order make happened to list it. A manifest that churns is a file
-- whose mtime lies about what changed.
local function test_render_is_order_independent()
  local a = modules.render("/r", {"o/a.lua", "o/b.lua", "o/c.lua"}, "o")
  local b = modules.render("/r", {"o/c.lua", "o/a.lua", "o/b.lua"}, "o")
  assert(a == b, "same closure, different order:\n" .. a .. "\n---\n" .. b)
end
test_render_is_order_independent()

-- Non-modules are dropped rather than rendered as something: a `.d.tl`
-- compiles to nothing and the graph's `.got` files are not imports.
local function test_render_drops_what_is_not_a_module()
  local text = modules.render("/r", {"o/a.lua", "o/x.tl.test.got"}, "o")
  local n = 0
  for _ in text:gmatch("\nmod ") do
    n = n + 1
  end
  assert(n == 1, "only the module should be listed, got: " .. text)
end
test_render_drops_what_is_not_a_module()

-- attach() is the other half of the channel: the file plus the argument
-- convention. Position 2 and 3, so the child's dispatcher sees the flag
-- before its first require and the program's own positionals move
-- together with it.
local function test_attach_puts_the_flag_after_the_program()
  local dir = fs.join(tmp, "modattach")
  assert(fs.makedirs(dir))
  local argv: {string} = {"/bin/cosmic", "o/t.lua", "--flag", "value"}
  modules.attach(argv, fs.join(dir, "t"), "/r", {"o/a.lua"})
  assert(argv[1] == "/bin/cosmic", "the program stays first")
  assert(argv[2] == "--modules", "got: " .. argv[2])
  assert(argv[3] == fs.join(dir, "t") .. modules.SUFFIX, "got: " .. argv[3])
  assert(argv[4] == "o/t.lua", "the target follows, got: " .. argv[4])
  assert(argv[6] == "value", "and its own arguments keep their order")
  local text = check.must(fs.read(argv[3]))
  assert(text:find("mod a /r/o/a.lua", 1, true), "got: " .. text)
end
test_attach_puts_the_flag_after_the_program()

-- A manifest that cannot be written is a MISS, not a failure: the child
-- then runs as an ordinary cosmic, which is the behaviour that shipped
-- for every release before in-project resolution existed.
local function test_attach_is_a_miss_when_it_cannot_write()
  local argv: {string} = {"/bin/cosmic", "o/t.lua"}
  modules.attach(argv, "/proc/self/mem/nope/t", "/r", {"o/a.lua"})
  assert(#argv == 2, "an unwritable manifest must not change the argv")
end
test_attach_is_a_miss_when_it_cannot_write()

-- The build directory exists in two places on purpose (the steps may
-- not reach into `_make`), so the ratchet is what keeps them one fact.
local function test_build_dir_agrees_with_the_model()
  assert(modules.BUILD_DIR == project.BUILD_DIR,
    "modules.BUILD_DIR (" .. modules.BUILD_DIR .. ") must equal " ..
    "project.BUILD_DIR (" .. project.BUILD_DIR .. ")")
end
test_build_dir_agrees_with_the_model()

print("all modules tests passed")
