local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local script = require("_cli.script")

local tmp = os.getenv("TEST_TMPDIR") or "/tmp"
local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))

local function test_script_loader_preserves_chunks_errors_and_compatibility()
  for _, ext in ipairs({"lua", "tl"}) do
    local path = fs.join(tmp, "script." .. ext)
    assert(fs.write(path, "#!/usr/bin/env cosmic\nreturn 42\n"))
    local loader = check.must(script.load_script_file(path))
    assert(loader() == 42)
    assert(debug.getinfo(loader, "S").source == "@" .. path)
    local old = check.must(require("_cli.main_handlers").load_script_file(path))
    assert(old() == 42, "existing handler API must forward unchanged")
    assert(fs.write(path, "this is not valid syntax )\n"))
    local broken, err = script.load_script_file(path)
    assert(not broken and err ~= nil)
    if ext == "tl" then
      assert(fs.write(path, "local value: string = 42\nreturn value\n"))
      local bad_type, type_err = script.load_script_file(path)
      assert(not bad_type and type_err:find("expected string", 1, true), type_err)
    end
  end
  local missing, err = script.load_script_file(fs.join(tmp, "absent-script.lua"))
  assert(not missing and err:find("absent-script.lua", 1, true))
end

local function test_manifest_scripts_do_not_load_unselected_handlers()
  local root = fs.join(tmp, "script-manifest")
  assert(fs.make_dirs(fs.join(root, "_cli")))
  local manifest = fs.join(root, "project.modules")
  assert(fs.write(manifest, "root " .. root .. "\nbuild o\n"))
  assert(fs.write(fs.join(root, "_cli/lint.tl"),
      "return {lint_file = function(_path: string, _limit: integer): boolean, string return true end}\n"))
  assert(fs.write(fs.join(root, "_cli/main_handlers.tl"),
      "local lint = require('_cli.lint')\nlocal _diags, _err = lint.lint_file('x', 10)\nreturn {}\n"))
  local probe = fs.join(root, "generator.lua")
  local marker = "assert(package.loaded['_cli.main_handlers'] == nil); print('entry reached')"
  assert(fs.write(probe, marker .. "\n"))
  local settings = env.list({set = {COSMIC_COVERAGE = "0", COSMIC_NO_WELCOME = "1"}})
  for _, args in ipairs({{cosmic, "--modules", manifest, "-e", marker},
      {cosmic, "--modules", manifest, probe}}) do
    local result = check.must(child.run(args, {env = settings}))
    assert(result.ok and result.stdout:find("entry reached", 1, true), result.stderr)
  end
  -- Fewer dispatcher imports must not mean different user manifest semantics.
  local explicit = check.must(child.run({cosmic, "--modules", manifest,
        "-e", "require('_cli.main_handlers')"}, {env = settings}))
  assert(not explicit.ok and explicit.stderr:find("given 2, expects 1", 1, true), explicit.stderr)
end

local function test_script_runtime_errors_keep_user_traceback()
  local path = fs.join(tmp, "script-error.lua")
  assert(fs.write(path, "error('user-script-error')\n"))
  local result = check.must(child.run({cosmic, path},
      {env = env.list({set = {COSMIC_COVERAGE = "0", COSMIC_NO_WELCOME = "1"}})}))
  assert(not result.ok and result.stderr:find("user-script-error", 1, true), result.stderr)
  -- Lua abbreviates long source paths in tracebacks; the user file remains.
  assert(result.stderr:find("script-error.lua:1", 1, true), result.stderr)
  assert(not result.stderr:find("/zip/main.lua:", 1, true), result.stderr)
end
