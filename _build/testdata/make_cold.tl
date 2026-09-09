--- Manual full-source empty-o proof; run from the repository root:
--- bin/cosmic _build/testdata/make_cold.tl <runtime|wrapper> <new-fixture-dir>
--- Only verified dependency artifacts are copied into o/. No built Lua or
--- code cache is reused. The selected runtime is invoked explicitly; after
--- release/pin activation use 'wrapper' to run the fixture's bin/cosmic.
local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

local runtime_arg = assert(arg[1], "runtime or wrapper required")
local root = fs.absolute_path(assert(arg[2], "new fixture directory required"))
local runtime = runtime_arg == "wrapper" and fs.join(root, "bin/cosmic") or fs.absolute_path(runtime_arg)
assert(not fs.stat(root), "fixture directory must not already exist")
assert(fs.make_dirs(root))
local listing = check.must(child.run({"git", "ls-files", "--cached", "--others", "--exclude-standard"}))
assert(listing.ok, listing.stderr)
for path in listing.stdout:gmatch("[^\n]+") do
  local dest = fs.join(root, path)
  assert(fs.make_dirs(fs.dirname(dest)))
  if fs.is_link(path) then
    assert(fs.symlink(check.must(fs.readlink(path)), dest))
  else
    assert(fs.copy(path, dest))
  end
end
assert(fs.make_dirs(fs.join(root, "o")))
local copied = check.must(child.run({"cp", "-R", "o/3p", fs.join(root, "o/3p")}))
assert(copied.ok, copied.stderr)
local bootstrap = check.must(child.run({"cp", "-R", "o/bootstrap", fs.join(root, "o/bootstrap")}))
assert(bootstrap.ok, bootstrap.stderr)
local lint_path = fs.join(root, "_cli/lint.tl")
local lint = check.must(fs.read(lint_path))
local wide, sites = lint:gsub("%(path: string%): {Diagnostic} | nil, string",
  "(path: string, _extra?: integer): {Diagnostic} | nil, string")
assert(sites == 2, "expected lint declaration and interface")
assert(fs.write(lint_path, wide))
local handlers_path = fs.join(root, "_cli/main_handlers.tl")
local handlers = check.must(fs.read(handlers_path))
local caller, calls = handlers:gsub("lint%.lint_file%(file%)", "lint.lint_file(file, 10)")
assert(calls == 1, "expected one handler call")
assert(fs.write(handlers_path, caller))
local result = check.must(child.run({runtime, "--make", "build"}, {cwd = root,
      env = env.list({set = {COSMIC_COVERAGE = "0", COSMIC_NO_WELCOME = "1",
            COSMIC_MAKE_ROOT = root}})}))
assert(fs.write(fs.join(root, "cold-build.log"), result.stdout .. result.stderr))
io.write("cold fixture: " .. root .. "\nexit: " .. tostring(result.code) .. "\n")
if not result.ok then io.stderr:write(result.stderr) end
os.exit(result.code or 1)
