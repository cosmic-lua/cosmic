--- A build refuses a `global` in any module it compiles
--- ([`build.compilation`]): each kind of declaration at its own
--- position, a global another module would have read, and a project
--- without one.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

Test.policy{ grants = { { path = "core", letters = "r" } } }

local built = assert(teal.load())

local REFUSED <const> = ": a global is not allowed in a cosmic build: it reaches other modules by no " ..
  "`require`, which is all a build's cache and its order see -- put the value in a module and " ..
  "`require` it"

--- Compiles the project of `files` (filename -> source) under `tmp/<case>`.
local function compile_project(tmp: string, case: string,
                               files: {string:string}): importer.Result | nil, string
  local root = tmp .. "/" .. case
  assert(Fs.mkdirs(root))
  for filename, source in pairs(files) do
    local parent = filename:match("^(.+)/[^/]+$")
    if parent ~= nil then
      assert(Fs.mkdirs(root .. "/" .. parent))
    end
    assert(Fs.write(root .. "/" .. filename, source))
  end
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local result, trouble = importer.compile(handle, built, "globals-test")
  assert(work.close(handle))
  return result, trouble
end

--- Each kind of global declaration is refused once, where its `global`
--- keyword is (or `function`, for one written with no keyword), whatever
--- its length or nesting.
local function test_each_kind_of_global_is_refused_at_its_line(tmp: string)
  local cases: {{string}} = {
    { "variable", "global count: integer = 0\n", "2:1" },
    { "bare", "global count: integer\n", "2:1" },
    { "names", "global a, b: integer\n", "2:1" },
    { "function", "global function f(): integer\n  return 1\nend\n", "2:1" },
    { "implicit", "function f(): integer\n  return 1\nend\n", "2:1" },
    { "generic", "function f<T>(x: T): T\n  return x\nend\n", "2:1" },
    { "record", "global record R\n  n: integer\nend\n", "2:1" },
    { "interface", "global interface I\n  n: integer\nend\n", "2:1" },
    { "enum", 'global enum E\n  "a"\nend\n', "2:1" },
    { "type", "global type T = integer\n", "2:1" },
    { "nested", "local function f(): integer\n  global w: integer = 1\n  return w\nend\n", "3:3" },
  }
  for _, c in ipairs(cases) do
    local result, trouble = compile_project(tmp, c[1], {
      ["main.tl"] = "local n = 1\n" .. c[2] .. "return n\n",
    })
    local want = "main.tl:" .. c[3] .. REFUSED
    assert(result == nil and trouble == want,
      c[1] .. ": wanted " .. want .. ", got " .. tostring(trouble))
  end
end

--- A global one module declares and another reads is refused where it is
--- declared, whichever of them the build would compile first: the
--- reader's own "unknown type" never stands in for it. `shared` sorts
--- after `user` here, so the reader is compiled first.
local function refused_at_the_declaration(tmp: string, declarer: string, reader: string)
  local _, trouble = compile_project(tmp, "leak-" .. declarer, {
    [declarer .. ".tl"] = "global record Shared\n  n: integer\nend\nreturn 1\n",
    [reader .. ".tl"] = "local s: Shared = { n = 1 }\nreturn s.n\n",
  })
  assert(trouble == declarer .. ".tl:1:1" .. REFUSED, tostring(trouble))
end

local function test_a_global_read_by_a_module_compiled_after_it_is_refused(tmp: string)
  refused_at_the_declaration(tmp, "a_shared", "b_user")
end

local function test_a_global_read_by_a_module_compiled_before_it_is_refused(tmp: string)
  refused_at_the_declaration(tmp, "b_shared", "a_user")
end

--- A `function NAME()` assigns to a local `NAME` where one is in scope,
--- which is legal Teal, and declares a global where none is: only that is
--- refused. Where the local is bound decides it: a local declared after
--- the function, or in a block or function that has ended, is no local at
--- the function.
local function test_a_function_over_a_local_of_its_name_is_no_global(tmp: string)
  local legal: {{string}} = {
    { "forward", "local f: function(): integer\nfunction f(): integer\n  return 1\nend\n" ..
        "return f\n" },
    { "redefined", "local function g(): integer\n  return 1\nend\n" ..
        "function g(): integer\n  return 2\nend\nreturn g\n" },
    { "nested", "local function outer(): integer\n  local h: function(): integer\n" ..
        "  function h(): integer\n    return 1\n  end\n  return h()\nend\nreturn outer\n" },
    { "parameter", "local function w(f: function(): integer): integer\n" ..
        "  function f(): integer\n    return 1\n  end\n  return f()\nend\nreturn w\n" },
    { "in-if", "local n = 1\nlocal f: function(): integer\nif n == 1 then\n" ..
        "  function f(): integer\n    return 1\n  end\nelse\n  function f(): integer\n    return 2\n  end\nend\nreturn f\n" },
  }
  for _, c in ipairs(legal) do
    local result, trouble = compile_project(tmp, "legal-" .. c[1], { ["main.tl"] = c[2] })
    assert(result ~= nil, c[1] .. ": " .. tostring(trouble))
  end
  local f = "function f(): integer\n  return 1\nend\n"
  local declared = "local f: function(): integer\n"
  local undeclared: {{string}} = {
    { "nested", "local function outer(): integer\n  function h(): integer\n    return 1\n" ..
        "  end\n  return h()\nend\nreturn outer\n", "2:3" },
    { "later", "local n = 1\n" .. f .. declared .. "return n\n", "2:1" },
    { "closed-do", "do\n  " .. declared .. "end\n" .. f .. "return 1\n", "4:1" },
    { "other-branch", "local n = 1\nif n == 1 then\n  " .. declared .. "else\n  " ..
        "function f(): integer\n    return 1\n  end\nend\nreturn n\n", "5:3" },
    { "closed-for", "for _ = 1, 2 do\n  " .. declared .. "end\n" .. f, "4:1" },
    { "closed-while", "while false do\n  " .. declared .. "end\n" .. f, "4:1" },
    { "closed-repeat", "repeat\n  " .. declared .. "until true\n" .. f, "4:1" },
    { "inner-function", "local function inner()\n  " .. declared .. "end\n" .. f ..
        "return inner\n", "4:1" },
  }
  for _, c in ipairs(undeclared) do
    local _, trouble = compile_project(tmp, "undeclared-" .. c[1], { ["main.tl"] = c[2] })
    assert(trouble == "main.tl:" .. c[3] .. REFUSED, c[1] .. ": " .. tostring(trouble))
  end
end

--- A global a `.d.tl` declares would reach each module the checker reads
--- after a `require` of it, and none before: the build refuses it, though
--- no module of the project is the declaration.
local function test_a_global_in_a_declaration_file_is_refused(tmp: string)
  local _, trouble = compile_project(tmp, "decl", {
    ["foo.d.tl"] = "global record Foo\n  n: integer\nend\n",
    ["a.tl"] = 'local _ = require("foo")\nreturn 1\n',
    ["b.tl"] = "local f: Foo = { n = 1 }\nreturn f.n\n",
  })
  assert(trouble == "foo.d.tl:1:1" .. REFUSED, tostring(trouble))
end

--- A global written in an example of a guide is refused in the file
--- extracted from the guide, as a module's own is.
local function test_a_global_in_a_guide_example_is_refused(tmp: string)
  local _, trouble = compile_project(tmp, "doc-guide", {
    ["doc/guides/g.md"] = "# g\n\n```teal\nglobal n: integer = 1\n```\n",
    ["lib.tl"] = "return 1\n",
  })
  assert(trouble ~= nil and trouble:find("doc/guides/g.md:", 1, true) == 1 and
      trouble:find(REFUSED, 1, true) ~= nil, tostring(trouble))
end

--- Every module's own name is the way to share, so a project that
--- requires what it uses compiles.
local function test_a_project_without_globals_compiles(tmp: string)
  local result, trouble = compile_project(tmp, "clean", {
    ["shared.tl"] = "local record Shared\n  n: integer\nend\nreturn Shared\n",
    ["user.tl"] = 'local type Shared = require("shared")\nlocal s: Shared = { n = 1 }\nreturn s.n\n',
  })
  assert(result ~= nil, tostring(trouble))
end
