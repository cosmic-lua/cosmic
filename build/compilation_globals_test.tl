--- A build refuses a `global` in any module it compiles: each kind of
--- declaration at its own position, a global another module would have
--- read, a `function NAME()` that declares one, and a project without one.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local importer = require("build.importer")
local work = require("build.work")

Test.policy{ cpu_features = true, grants = { { path = "core", letters = "r" } } }

--- What the build says of a global a declaration file of the project declares.
local REFUSED <const> = ": a global is not allowed in a cosmic build: it reaches other modules by no " ..
  "`require`, which is all a build's cache and its order see -- put the value in a module and " ..
  "`require` it"

--- What the grammar says of a `global`, and of a `function f()` that no local `f` is in scope for.
local GLOBAL <const> = ": `global` declares a global, which only a declaration file does (global_in_program): write " ..
  "`local`; a program's globals are exactly the ones a declaration file (`.d.tl`) declares"
--- What the grammar says of a `function NAME()` that declares a global.
local function bare(name: string): string
  return ": `function " .. name .. "(...)` declares a global (bare_function): write `local function " .. name ..
    "(...)`; a program's globals are the ones a declaration file declares"
end

--- Compiles the project of `files` (filename -> source) under `tmp/<case>`: the result, or nil and what the build
--- refused of it, one message to a line.
local function compile_project(tmp: string, case: string,
                               files: {string:string}): importer.Result?, string
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
  assert(work.stage(handle, { own = false }))
  local result, trouble = importer.compile(handle, "globals-test")
  assert(work.close(handle))
  if result ~= nil and #result.refused > 0 then
    return nil, table.concat(result.refused, "\n")
  end
  return result, trouble
end

--- A module `source` of a case, and the position `at` ("line:column") that its refusal names, with `message` where it
--- is not the refusal of a `global`.
local record Case
  name: string
  source: string
  at: string
  message?: string
  --- The name a `function NAME()` of the source declares, where it is not `f`.
  of?: string
end

--- Each kind of global declaration is refused once, where its `global`
--- keyword is (or `function`, for one written with no keyword), whatever
--- its length or nesting.
local function test_each_kind_of_global_is_refused_at_its_line(tmp: string)
  local cases: {Case} = {
    { name = "variable", source = "global count: integer = 0\n", at = "2:1" },
    { name = "bare", source = "global count: integer\n", at = "2:1" },
    { name = "names", source = "global a, b: integer\n", at = "2:1" },
    { name = "function", source = "global function f(): integer\n  return 1\nend\n", at = "2:1" },
    { name = "implicit", source = "function f(): integer\n  return 1\nend\n", at = "2:1", message = bare("f") },
    { name = "generic", source = "function f<T>(x: T): T\n  return x\nend\n", at = "2:1", message = bare("f") },
    { name = "record", source = "global record R\n  n: integer\nend\n", at = "2:1" },
    { name = "interface", source = "global interface I\n  n: integer\nend\n", at = "2:1" },
    { name = "enum", source = 'global enum E\n  "a"\nend\n', at = "2:1" },
    { name = "type", source = "global type T = integer\n", at = "2:1" },
    { name = "nested", source = "local function f(): integer\n  global w: integer = 1\n  return w\nend\n", at = "3:3" },
  }
  for _, c in ipairs(cases) do
    local result, trouble = compile_project(tmp, c.name, {
      ["main.tl"] = "local n = 1\n" .. c.source .. "return n\n",
    })
    local want = "main.tl:" .. c.at .. (c.message or GLOBAL)
    assert(result == nil and trouble == want, c.name .. ": wanted " .. want .. ", got " .. trouble)
  end
end

--- A global one module declares and another reads is refused where it is
--- declared, whichever of them the build would compile first: the
--- reader's own "unknown type" never stands in for it. `shared` sorts
--- after `user` here, so the reader is compiled first.
local function refused_at_the_declaration(tmp: string, declarer: string, reader: string)
  local _, trouble = compile_project(tmp, "leak-" .. declarer, {
    [declarer .. ".tl"] = "global record Shared\n  n: integer\nend\nreturn 1\n",
    [reader .. ".tl"] = "local s: Shared = { n = 1 }\nlocal n: integer = s.n\nreturn n\n",
  })
  -- The declaration's refusal comes first, and the reader's own (it names no `Shared`) follows it.
  local first = declarer .. ".tl:1:1" .. GLOBAL
  assert(trouble:sub(1, #first) == first, trouble)
end

local function test_a_global_read_by_a_module_compiled_after_it_is_refused(tmp: string)
  refused_at_the_declaration(tmp, "a_shared", "b_user")
end

local function test_a_global_read_by_a_module_compiled_before_it_is_refused(tmp: string)
  refused_at_the_declaration(tmp, "b_shared", "a_user")
end

--- A `function NAME()` is the declaration of a global whatever binds `NAME`: the grammar reads no assignment to a local
--- in it, so each form below is refused at its `function`, and the assignment of a function literal that the refusal's fix
--- stands for compiles where a local binds the name.
local function test_a_function_over_a_name_is_a_global_whatever_binds_it(tmp: string)
  local f = "function f(): integer\n  return 1\nend\n"
  local declared = "local f: function(): integer\n"
  --- The forms that name a local, and where each is refused.
  local bound: {Case} = {
    { name = "forward", source = declared .. f .. "return f\n", at = "2:1" },
    { name = "redefined", source = "local function g(): integer\n  return 1\nend\n" ..
        "function g(): integer\n  return 2\nend\nreturn g\n", at = "4:1", of = "g" },
    { name = "nested", source = "local function outer(): integer\n  local h: function(): integer\n" ..
        "  function h(): integer\n    return 1\n  end\n  return h()\nend\nreturn outer\n", at = "3:3", of = "h" },
    { name = "parameter", source = "local function w(f: function(): integer): integer\n" ..
        "  function f(): integer\n    return 1\n  end\n  return f()\nend\nreturn w\n", at = "2:3" },
  }
  for _, c in ipairs(bound) do
    local _, trouble = compile_project(tmp, "bound-" .. c.name, { ["main.tl"] = c.source })
    local want = "main.tl:" .. c.at .. bare(c.of or "f")
    assert(trouble:sub(1, #want) == want, c.name .. ": " .. trouble)
    local assigned = c.source:gsub("\n(%s*)function ([%w_]+)%(", "\n%1%2 = function(")
    local result, why = compile_project(tmp, "assigned-" .. c.name, { ["main.tl"] = assigned })
    assert(result ~= nil, c.name .. ": " .. why)
  end
  local undeclared: {Case} = {
    { name = "nested", source = "local function outer(): integer\n  function h(): integer\n    return 1\n" ..
        "  end\n  return h()\nend\nreturn outer\n", at = "2:3", of = "h" },
    { name = "later", source = "local n = 1\n" .. f .. declared .. "return n\n", at = "2:1" },
    { name = "closed-do", source = "do\n  " .. declared .. "end\n" .. f .. "return 1\n", at = "4:1" },
    { name = "other-branch", source = "local n = 1\nif n == 1 then\n  " .. declared .. "else\n  " ..
        "function f(): integer\n    return 1\n  end\nend\nreturn n\n", at = "5:3" },
    { name = "closed-for", source = "for _ = 1, 2 do\n  " .. declared .. "end\n" .. f, at = "4:1" },
    { name = "closed-while", source = "while false do\n  " .. declared .. "end\n" .. f, at = "4:1" },
    { name = "closed-repeat", source = "repeat\n  " .. declared .. "until true\n" .. f, at = "4:1" },
    { name = "inner-function", source = "local function inner()\n  " .. declared .. "end\n" .. f ..
        "return inner\n", at = "4:1" },
  }
  for _, c in ipairs(undeclared) do
    local _, trouble = compile_project(tmp, "undeclared-" .. c.name, { ["main.tl"] = c.source })
    local want = "main.tl:" .. c.at .. bare(c.of or "f")
    assert(trouble:sub(1, #want) == want, c.name .. ": " .. trouble)
  end
end

--- A global a `.d.tl` of the project declares would reach each module the checker reads after a `require` of it, and
--- none before: the build refuses it, though no module of the project is the declaration. (The declarations of the
--- standard library are the tool's own.)
local function test_a_global_in_a_declaration_file_is_refused(tmp: string)
  local _, trouble = compile_project(tmp, "decl", {
    ["foo.d.tl"] = "--- @kind binding\nglobal record Foo\n  n: integer\nend\n",
    ["a.tl"] = 'local _ = require("foo")\nlocal n: integer = 1\nreturn n\n',
    ["b.tl"] = "local f: Foo = { n = 1 }\nlocal n: integer = f.n\nreturn n\n",
  })
  assert(trouble == "foo.d.tl:2:1" .. REFUSED, trouble)
end

--- A global written in an example of a guide is refused in the file
--- extracted from the guide, as a module's own is.
local function test_a_global_in_a_guide_example_is_refused(tmp: string)
  local _, trouble = compile_project(tmp, "doc-guide", {
    ["doc/guides/g.md"] = "# g\n\n```teal\nglobal n: integer = 1\n```\n",
    ["lib.tl"] = "local n: integer = 1\nreturn n\n",
  })
  assert(trouble:find("doc/guides/g.md:", 1, true) == 1 and trouble:find(GLOBAL, 1, true) ~= nil, trouble)
end

--- Every module's own name is the way to share, so a project that
--- requires what it uses compiles.
local function test_a_project_without_globals_compiles(tmp: string)
  local result, trouble = compile_project(tmp, "clean", {
    ["shared.tl"] = "local record Shared\n  n: integer\nend\nreturn Shared\n",
    ["user.tl"] = 'local type Shared = require("shared")\nlocal s: Shared = { n = 1 }\nlocal n: integer = s.n\nreturn n\n',
  })
  assert(result ~= nil, tostring(trouble))
end
