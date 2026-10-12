--- The declarations of the C checker tell the truth about nil: a rule
--- that finds nothing in an expression answers nil, a syntax tree names no
--- address or position for a node the dump gives none, and a local a call
--- hands back is a record or none. Each test drives the paths a
--- declaration once lied on and asks a checked run
--- (`cosmic test --check-types`) whether a value crossed a typed boundary
--- under build/ as a kind its type does not admit; in any other run the
--- tests skip.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local TypeWatch = require("build.type_watch")
local c = require("build.c")
local tree = require("build.c.tree")

--- What the checker reads of the core's C, as build/c/rules_test.tl
--- declares it.
Test.policy{
  profiles = { "system" },
  grants = {
    { path = "bin/cosmic-bootstrap", letters = "r" },
    { path = "bin/zig", letters = "r" },
    { path = "bin/zig.pin", letters = "r" },
    { path = "ci/cosmic-driver.pin", letters = "r" },
    { path = "core/", letters = "r" },
    { path = "vendor/bzip2/", letters = "r" },
    { path = "vendor/cares/include/", letters = "r" },
    { path = "vendor/curl/include/", letters = "r" },
    { path = "vendor/lua/src/", letters = "r" },
    { path = "vendor/mbedtls/include/", letters = "r" },
    { path = "vendor/mbedtls/tf-psa-crypto/", letters = "r" },
    { path = "vendor/miniz/", letters = "r" },
    { path = "vendor/sqlite/", letters = "r" },
    { path = "vendor/xz/src/liblzma/api/", letters = "r" },
    { path = "vendor/yyjson/src/", letters = "r" },
    { path = "/cache/bootstrap", letters = "rwxc" },
    { path = "/cache/zig", letters = "rwxc" },
  },
  env = { "ALL_PROXY", "COSMIC_BOOTSTRAP", "COSMIC_BOOTSTRAP_ATTEMPTS", "COSMIC_BOOTSTRAP_VERIFY",
    "COSMIC_ZIG", "COSMIC_ZIG_CACHE", "COSMIC_ZIG_GLOBAL_CACHE", "CURL_CA_BUNDLE", "HTTPS_PROXY",
    "HTTP_PROXY", "NO_PROXY", "SSL_CERT_DIR", "SSL_CERT_FILE", "all_proxy", "http_proxy",
    "https_proxy", "no_proxy" },
}

local root = assert(Fs.absolute("."))

--- Fails, listing what `during` met under build/, unless it met nothing.
local function honest(what: string, fn: function())
  local found = TypeWatch.during(fn, "build/")
  assert(#found == 0, what .. ": " .. #found .. " violations:\n" .. table.concat(found, "\n"))
end

--- A dump with a call that names no function, and a body that has no
--- operator.
local function test_the_c_tree_answers_what_the_dump_leaves_out()
  honest("build.c.tree", function()
    local dump = table.concat({
      "TranslationUnitDecl 0x1 <<invalid sloc>> <invalid sloc>",
      "|-FunctionDecl 0x3 <core/a.c:4:1, line:7:1> line:4:12 used f 'int (lua_State *)' static",
      "| `-CompoundStmt 0x5 <col:28, line:7:1>",
      "|   `-CallExpr 0x6 <line:6:3, col:9> 'int'",
      "`-VarDecl 0x8 <line:9:1, col:9> col:5 x 'int'",
    }, "\n")
    -- Read with a root to take off the files' names, and with none.
    assert(#tree.parse(dump, "/tree") == 2)
    local decls = tree.parse(dump)
    assert(#decls == 2)
    local body = decls[1].children[1]
    local call = body.children[1]
    assert(tree.callee(call) == nil and tree.operator(body) == nil)
    assert(tree.referent(call) == nil)
  end)
end

--- The rules over C that hands buffers, allocations and statements a
--- status around: every one answers nil where an expression is none of
--- what it looks for.
local function test_the_rules_over_the_cores_c_answer_as_declared()
  honest("build.c.rules", function()
    local files = { "core/sqlite.c", "core/store.c", "core/syscalls_fs.c", "core/surface.c" }
    for i, outcome in ipairs(c.check(root, files)) do
      assert(outcome.findings ~= nil, files[i] .. ": " .. tostring(outcome.trouble))
    end
  end)
end
