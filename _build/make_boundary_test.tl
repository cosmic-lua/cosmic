local boundary = require("_build.make_boundary")
local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

local function test_fresh_make_startup_has_only_the_named_pinned_boundary()
  local root = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "make-boundary")
  assert(fs.make_dirs(fs.join(root, "_cli")))
  assert(fs.write(fs.join(root, ".cosmicignore"), "o\n"))
  local names: {string} = {}
  for _, name in ipairs(boundary.modules) do
    names[#names + 1] = string.format("[%q] = true", name)
  end
  -- This Lua handler is the first protected command import. No package.loaded
  -- resets: the child reports its actual fresh dispatcher/bootstrap state.
  local source = "local expected = {" .. table.concat(names, ",") .. "}\n" .. [[
for name in pairs(package.loaded) do
  if name:match('^cosmic[.]') or name:match('^_make[.]') or
    name:match('^_cli[.]') or name == 'tl' then
    -- Hints install after the make searcher and before this handler.
    if name ~= '_cli.require_hints' then
      assert(expected[name], 'unlisted startup module: ' .. name)
      expected[name] = nil
    end
  end
end
assert(next(expected) == nil, 'missing boundary module: ' .. tostring(next(expected)))
return {handle_make = function() print('boundary-ok'); return 0 end}
]]
  assert(fs.write(fs.join(root, "_cli/main_handlers.lua"), source))
  local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))
  local result = check.must(child.run({cosmic, "--make", "build"},
      {env = env.list({set = {COSMIC_MAKE_ROOT = root,
              COSMIC_COVERAGE = "0", COSMIC_NO_WELCOME = "1"}})}))
  assert(result.ok and result.stdout:find("boundary-ok", 1, true), result.stdout .. result.stderr)
end
