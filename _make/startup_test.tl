local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local parse = require("_cli.parse")
local startup = require("_make.startup")

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))

local function test_effective_make_follows_dispatcher_precedence()
  local saved = arg
  for _, argv in ipairs({{"--make", "build"}, {"--make", "check"}, {"--make=build"}}) do
    _G.arg = argv
    assert(startup.effective_make(parse.parse_args()))
  end
  for _, argv in ipairs({{"s.lua", "--make", "build"},
      {"--version", "--make", "build"}, {"--make", "help"},
      {"--help", "--make", "build"}, {"--compile", "s.tl", "--make", "build"},
      {"--diff", "old-cosmic", "--make", "build"},
      {"-c", "true", "--make", "build"}}) do
    _G.arg = argv
    assert(not startup.effective_make(parse.parse_args()), table.concat(argv, " "))
  end
  _G.arg = {"--make", "build"}
  local opts = parse.parse_args()
  opts.embed = {"environment-fallback"}
  assert(not startup.effective_make(opts))
  opts.embed = {}
  opts.extract = "environment-fallback"
  assert(not startup.effective_make(opts))
  _G.arg = saved
end

local function test_early_make_loads_tree_handler_but_keeps_boundary_and_scripts_pinned()
  local root = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "make-startup")
  assert(fs.make_dirs(fs.join(root, "_cli")))
  assert(fs.make_dirs(fs.join(root, "_make")))
  assert(fs.make_dirs(fs.join(root, "o/_cli")))
  assert(fs.write(fs.join(root, ".cosmicignore"), "o\n"))
  assert(fs.write(fs.join(root, "_cli/parse.lua"), "error('tree parser loaded')\n"))
  assert(fs.write(fs.join(root, "_make/root.lua"), "error('tree root loaded')\n"))
  assert(fs.write(fs.join(root, "_cli/main_handlers.lua"), [[
local root = require('_make.root')
assert(debug.getinfo(root.discover, 'S').source:find('/zip/', 1, true))
return {refuse_combined_file_commands = function() return false end,
  handle_make = function() print('TREE_HANDLER'); return 0 end}
]]))
  assert(fs.write(fs.join(root, "o/_cli/main_handlers.lua"), "error('built handler loaded')\n"))
  local settings = env.list({set = {COSMIC_COVERAGE = "0", COSMIC_NO_WELCOME = "1",
        COSMIC_MAKE_ROOT = root}})
  for _, argv in ipairs({{cosmic, "--make", "build"}, {cosmic, "--make=build"},
      {cosmic, "--make", "build", "--", "paths"}}) do
    local r = check.must(child.run(argv, {env = settings}))
    assert(r.ok and r.stdout:find("TREE_HANDLER", 1, true), r.stdout .. r.stderr)
  end
  local script = fs.join(root, "ordinary.lua")
  assert(fs.write(script, "print(debug.getinfo(require('_cli.main_handlers').handle_make, 'S').source)\n"))
  for _, argv in ipairs({{cosmic, script, "--make", "build"},
      {cosmic, "--", script, "--make", "build"},
      {cosmic, "--version", "--make", "build"}, {cosmic, "--make", "help"}}) do
    local ordinary = check.must(child.run(argv, {cwd = root, env = settings}))
    assert(ordinary.ok and not ordinary.stdout:find("TREE_HANDLER", 1, true),
      ordinary.stdout .. ordinary.stderr)
    if argv[2] == script or argv[3] == script then
      assert(ordinary.stdout:find("@/zip/_cli/main_handlers.lua", 1, true), ordinary.stdout)
    end
  end
end

local function test_explicit_manifest_is_not_replaced_by_make_root()
  local tmp = os.getenv("TEST_TMPDIR") or "/tmp"
  local mapped = fs.join(tmp, "manifest-handler.lua")
  assert(fs.write(mapped, "return {handle_make = function() print('MANIFEST_HANDLER'); return 0 end}\n"))
  local manifest = fs.join(tmp, "explicit.modules")
  assert(fs.write(manifest, "root " .. tmp .. "\nbuild o\nmod _cli.main_handlers " .. mapped .. "\n"))
  local result = check.must(child.run({cosmic, "--modules", manifest, "--make", "build"},
      {env = env.list({set = {COSMIC_NO_WELCOME = "1", COSMIC_COVERAGE = "0",
              COSMIC_MAKE_ROOT = fs.join(tmp, "make-startup")}})}))
  assert(result.ok and result.stdout:find("MANIFEST_HANDLER", 1, true), result.stdout .. result.stderr)
  assert(not result.stdout:find("TREE_HANDLER", 1, true), result.stdout)
end

local function test_failed_discovery_preserves_help_unknown_verb_and_root_refusal()
  local root = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "does-not-exist")
  local settings = env.list({set = {COSMIC_NO_WELCOME = "1", COSMIC_COVERAGE = "0", COSMIC_MAKE_ROOT = root}})
  local help = check.must(child.run({cosmic, "--make", "help"}, {env = settings}))
  assert(help.ok, help.stderr)
  local unknown = check.must(child.run({cosmic, "--make", "absent-verb"}, {env = settings}))
  assert(not unknown.ok and unknown.stderr:find("unknown verb", 1, true), unknown.stderr)
  assert(not unknown.stderr:find("not a directory", 1, true), unknown.stderr)
  local build = check.must(child.run({cosmic, "--make", "build"}, {env = settings}))
  assert(not build.ok and build.stderr:find("not a directory", 1, true), build.stderr)
end

local function test_environment_embed_wins_before_make_installation()
  local tmp = os.getenv("TEST_TMPDIR") or "/tmp"
  local root = fs.join(tmp, "make-startup")
  local result = check.must(child.run({cosmic, "--make", "build", "--output", fs.join(tmp, "unused")},
      {env = env.list({set = {COSMIC_NO_WELCOME = "1", COSMIC_COVERAGE = "0", COSMIC_MAKE_ROOT = root,
              COSMIC_EMBED = fs.join(tmp, "no-such-embed-input")}})}))
  assert(not result.ok and not result.stdout:find("TREE_HANDLER", 1, true), result.stdout .. result.stderr)
  assert((result.stdout .. result.stderr):find("no-such-embed-input", 1, true), result.stdout .. result.stderr)
end
