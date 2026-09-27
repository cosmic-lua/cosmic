--- `cosmic bom`, run in this process, over the running program's own
--- rows (build/bom_test.tl holds what they are made from).

local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Test = require("cosmic.test")
local invoke = require("build.invoke")

--- The verb reads the program's own database through a handle
--- (`Store.databases()`), which reads every module's rows too.
Test.needs{ store = true }

--- `cosmic bom` answers from the running binary's own rows: each
--- component a line, `--json` a document naming the same components,
--- and `--licenses` every notice.
local function test_the_verb_prints_the_binary_s_own_rows(tmp: string)
  local listed = invoke.run({ "bom" }, { cwd = tmp })
  assert(listed.code == 0, listed.stderr)
  assert(listed.stdout:find("\nlua %S+  MIT\n") or listed.stdout:find("^lua %S+  MIT\n"),
    listed.stdout)
  -- Data is what `cosmic refresh` updates, and the line says so.
  assert(listed.stdout:find("\ntzdata %S+  %S+  %(data: `cosmic refresh` updates it%)\n"), listed.stdout)
  assert(listed.stdout:find("\ncacert %S+  %S+  %(data: `cosmic refresh` updates it%)\n"), listed.stdout)
  local path = tmp .. "/bom.json"
  local written = invoke.run({ "bom", "--json", path }, { cwd = tmp })
  assert(written.code == 0, written.stderr)
  local decoded = assert(Json.decode_object((assert(Fs.read(path)))))
  local names: {string:boolean} = {}
  for _, component in ipairs(decoded.components as {{string:any}}) do
    names[tostring(component.name)] = true
  end
  assert(names["lua"] and names["curl"] and names["musl"], "the document names the components")
  local notices = invoke.run({ "bom", "--licenses" }, { cwd = tmp })
  assert(notices.code == 0, notices.stderr)
  assert(notices.stdout:find("Lua.org, PUC-Rio", 1, true), "lua's notice is printed")
  assert(notices.stdout:find("== sqlite", 1, true), "a component with no notice is named")
end
