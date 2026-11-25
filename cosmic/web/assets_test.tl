local Assets = require("cosmic.web.assets")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local source_run = require("cosmic.internal.source_run")
local sys = require("cosmic.sys")

Test.policy{}

local function test_memory_holds_files_with_a_hash_a_tag_and_a_type()
  local source = Assets.memory({ ["css/app.css"] = "body{}", ["a.txt"] = "hi" })
  local asset = assert(source:get("css/app.css"))
  assert(asset.path == "css/app.css" and asset.data == "body{}" and asset.size == 6)
  assert(asset.sha256 == Hash.hex_sha256("body{}"))
  assert(asset.etag == '"' .. asset.sha256:sub(1, 32) .. '"')
  assert(asset.type == "text/css; charset=utf-8" and asset.mtime == 0 and asset.gzip == nil)
  local paths = source:paths()
  assert(#paths == 2 and paths[1] == "a.txt" and paths[2] == "css/app.css")
  assert(source:dynamic() == false)
end

local function test_a_missing_or_malformed_path_is_a_miss_with_a_reason()
  local source = Assets.memory({ ["a.txt"] = "hi" })
  for _, path in ipairs({ "b.txt", "", "/a.txt", "../a.txt", "x/../a.txt", "./a.txt", "a//b",
      "a.txt/", "a\\b", "a\0b" }) do
    local asset, why = source:get(path)
    assert(asset == nil and why:find("no such asset", 1, true) ~= nil, path)
  end
end

local function test_memory_refuses_a_key_that_is_no_relative_path()
  assert(Test.raises(function() Assets.memory({ ["/abs"] = "x" }) end):find("absolute", 1, true))
  assert(Test.raises(function() Assets.memory({ ["../up"] = "x" }) end):find("'..'", 1, true))
end

local function test_integrity_is_the_base64_digest_and_defaults_to_sha384()
  local asset = assert(Assets.memory({ ["a.js"] = "alert(1)" }):get("a.js"))
  local want = "sha384-" .. Codec.base64(Hash.digest("sha384", "alert(1)"))
  assert(asset:integrity() == want and asset:integrity("sha384") == want)
  assert(asset:integrity("sha256") == "sha256-" .. Codec.base64(Hash.digest("sha256", "alert(1)")))
  assert(asset:integrity("sha512"):sub(1, 7) == "sha512-")
end

local function test_memory_can_hold_a_gzip_variant_of_a_file_worth_it()
  local css = ("a { color: red }\n"):rep(200)
  local source = Assets.memory({ ["a.css"] = css, ["tiny.css"] = "a{}" }, { gzip = true })
  assert(assert(source:get("a.css")).gzip ~= nil)
  assert(assert(source:get("tiny.css")).gzip == nil)
  assert(assert(Assets.memory({ ["a.css"] = css }):get("a.css")).gzip == nil)
end

local function test_directory_reads_a_file_again_when_it_changes(tmp: string)
  assert(Fs.write(tmp .. "/a.txt", "one"))
  assert(Fs.set_mtime(tmp .. "/a.txt", 1000000000))
  local source = Assets.directory(tmp)
  local first = assert(source:get("a.txt"))
  assert(first.data == "one" and first.mtime == 1000000000)
  assert(assert(source:get("a.txt")) == first, "an unchanged file is not read again")
  assert(Fs.write(tmp .. "/a.txt", "two!"))
  local second = assert(source:get("a.txt"))
  assert(second.data == "two!" and second.sha256 ~= first.sha256)
  assert(source:dynamic() == true)
  assert(Fs.remove(tmp .. "/a.txt"))
  assert(source:get("a.txt") == nil)
end

local function test_directory_refuses_a_link_out_of_the_root_and_a_directory(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root/sub"))
  assert(Fs.write(tmp .. "/secret.txt", "TOPSECRET"))
  assert(Fs.write(tmp .. "/root/ok.txt", "fine"))
  assert(Fs.write(tmp .. "/root/sub/in.txt", "inner"))
  assert(Fs.symlink(tmp .. "/secret.txt", tmp .. "/root/out.txt"))
  assert(Fs.symlink(tmp, tmp .. "/root/up"))
  assert(Fs.symlink("sub/in.txt", tmp .. "/root/inside.txt"))
  assert(Fs.symlink("../secret.txt", tmp .. "/root/sub/rel.txt"))
  local source = Assets.directory(tmp .. "/root")
  assert(assert(source:get("ok.txt")).data == "fine")
  assert(assert(source:get("inside.txt")).data == "inner", "a link that stays under the root is followed")
  for _, path in ipairs({ "out.txt", "up/secret.txt", "sub/rel.txt", "sub", "", "missing.txt" }) do
    local asset = source:get(path)
    assert(asset == nil, path)
  end
end

local function test_directory_lists_its_files_without_the_hidden_ones(tmp: string)
  assert(Fs.mkdirs(tmp .. "/.git"))
  assert(Fs.mkdirs(tmp .. "/css"))
  assert(Fs.write(tmp .. "/.git/config", "x"))
  assert(Fs.write(tmp .. "/.env", "x"))
  assert(Fs.write(tmp .. "/css/b.css", "x"))
  assert(Fs.write(tmp .. "/a.txt", "x"))
  local paths = Assets.directory(tmp):paths()
  assert(#paths == 2 and paths[1] == "a.txt" and paths[2] == "css/b.css")
end

local function test_directory_refuses_a_file_past_the_embedded_limit(tmp: string)
  assert(Fs.write(tmp .. "/big.bin", ("x"):rep(16 * 1024 * 1024 + 1)))
  local asset, why = Assets.directory(tmp):get("big.bin")
  assert(asset == nil and why:find("16 MiB", 1, true) ~= nil)
end

--- Calls `fn` as a program whose database records `main` as its main
--- module ("" for the tool, which records none).
local function as_program(main: string, fn: function())
  local real = Store.meta
  Store.meta = function(key: string): string? -- checked: field_fixed
    if key == "main" then return main end
    return real(key)
  end
  local ok, err = pcall(function(): any
    fn()
    return nil -- checked: any_use
  end)
  Store.meta = real -- checked: field_fixed
  assert(ok, tostring(err))
end

local function test_default_reads_the_directory_in_dev_and_for_a_program_not_built(tmp: string)
  assert(Fs.write(tmp .. "/a.txt", "x"))
  local lines: mut {string} = {}
  local logged = function(text: string) lines[#lines + 1] = text end
  as_program("", function()
    local dev = Assets.default({ dev = true, root = tmp, log = logged })
    assert(dev:dynamic() and #lines == 0 and assert(dev:get("a.txt")).data == "x")
    local fallback = Assets.default({ root = tmp, log = logged })
    assert(fallback:dynamic() and #lines == 1 and lines[1]:find("not a built program", 1, true) ~= nil)
    assert(assert(fallback:get("a.txt")).data == "x")
  end)
end

local function test_default_of_a_built_program_serves_only_what_it_carries(tmp: string)
  assert(Fs.write(tmp .. "/a.txt", "x"))
  local lines: mut {string} = {}
  local logged = function(text: string) lines[#lines + 1] = text end
  as_program("cmd.site.main", function()
    local source = Assets.default({ root = tmp, log = logged })
    assert(not source:dynamic(), "an embedded source, not the directory")
    assert(source:get("a.txt") == nil, "the directory beside a built program is not served")
    assert(#source:paths() == 0 and #lines == 0)
    local dev = Assets.default({ dev = true, root = tmp, log = logged })
    assert(assert(dev:get("a.txt")).data == "x", "dev still reads the directory")
  end)
end

--- From disk, with no root given, a program's own `cmd/<name>/static/` is
--- laid over `static/`, as a built one carries them: in dev, and for a
--- `cmd/<name>/main.tl` run from its source, which the run records. A root
--- given is read alone, and a run that is no program's main reads
--- `static/` alone.
local function test_default_lays_a_programs_own_directory_over_static_from_disk(tmp: string)
  assert(Fs.mkdirs(tmp .. "/static"))
  assert(Fs.mkdirs(tmp .. "/cmd/spam/static"))
  assert(Fs.write(tmp .. "/static/app.css", "shared"))
  assert(Fs.write(tmp .. "/static/logo.png", "logo"))
  assert(Fs.write(tmp .. "/cmd/spam/static/app.css", "spam's"))
  assert(Fs.write(tmp .. "/cmd/spam/static/only.txt", "spam alone"))
  local was = assert(Fs.absolute("."))
  local main = source_run.main
  local lines: mut {string} = {}
  local logged = function(text: string) lines[#lines + 1] = text end
  local ok, err = pcall(function()
    assert(sys.chdir(tmp))
    source_run.main = "cmd.spam.main"
    as_program("", function()
      for _, source in ipairs({ Assets.default({ dev = true }), Assets.default({ log = logged }) }) do
        assert(assert(source:get("app.css")).data == "spam's" and assert(source:get("logo.png")).data == "logo")
        assert(assert(source:get("only.txt")).data == "spam alone")
        assert(table.concat(source:paths(), " ") == "app.css logo.png only.txt", table.concat(source:paths(), " "))
      end
      assert(#lines == 1 and lines[1]:find('"cmd/spam/static" over "static"', 1, true) ~= nil, lines[1])
      local given = Assets.default({ dev = true, root = "static" })
      assert(assert(given:get("app.css")).data == "shared" and given:get("only.txt") == nil, "a root given is read alone")
      source_run.main = "notes"
      local other = Assets.default({ dev = true })
      assert(assert(other:get("app.css")).data == "shared" and other:get("only.txt") == nil, "no program, no overlay")
    end)
  end)
  source_run.main = main
  assert(sys.chdir(was))
  assert(ok, tostring(err))
end

local function test_directory_refuses_a_hidden_file_as_paths_does(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root/.git"))
  assert(Fs.write(tmp .. "/root/.env", "SECRET"))
  assert(Fs.write(tmp .. "/root/.git/config", "SECRET"))
  assert(Fs.write(tmp .. "/root/a.txt", "x"))
  local source = Assets.directory(tmp .. "/root")
  assert(source:get("a.txt") ~= nil)
  for _, path in ipairs({ ".env", ".git/config" }) do
    local asset, why = source:get(path)
    assert(asset == nil and why:find("hidden", 1, true) ~= nil, path)
  end
end

local function test_directory_of_the_filesystem_root_serves_its_files(tmp: string)
  assert(Fs.write(tmp .. "/f.txt", "inside"))
  local real = assert(Fs.absolute(tmp))
  local asset, why = Assets.directory("/"):get(real:sub(2) .. "/f.txt")
  assert(asset ~= nil and asset.data == "inside", why)
end

--- A path is found in the first layer that holds it; `paths` lists
--- each path once.
local function test_layered_answers_each_path_from_the_first_source_that_holds_it()
  local over = Assets.memory({ ["a.css"] = "over", ["b.css"] = "b" })
  local under = Assets.memory({ ["a.css"] = "under", ["c.css"] = "c" })
  local both = Assets.layered({ over, under })
  assert(assert(both:get("a.css")).data == "over")
  assert(assert(both:get("c.css")).data == "c")
  local none, why = both:get("d.css")
  assert(none == nil and why:find("d.css", 1, true) ~= nil, why)
  assert(table.concat(both:paths(), ",") == "a.css,b.css,c.css", table.concat(both:paths(), ","))
  assert(not both:dynamic())
end

local function test_under_names_the_files_below_a_prefix_by_the_rest_of_their_paths()
  local source = Assets.memory({ ["images/a.png"] = "a", ["images/sub/b.png"] = "b", ["top.png"] = "t" })
  local images = Assets.under(source, "images/")
  local a = assert(images:get("a.png"))
  assert(a.data == "a" and a.path == "a.png" and a.type == "image/png", a.path)
  assert(images:get("top.png") == nil and images:get("images/a.png") == nil)
  assert(images:get("../top.png") == nil, "a path out of the prefix was answered")
  assert(table.concat(images:paths(), ",") == "a.png,sub/b.png", table.concat(images:paths(), ","))
end

local function test_only_answers_the_names_it_lists()
  local source = Assets.memory({ ["a.css"] = "a", ["b.css"] = "b" })
  local one = Assets.only(source, { "a.css", "missing.css" })
  assert(assert(one:get("a.css")).data == "a")
  local none, why = one:get("b.css")
  assert(none == nil and why:find("b.css", 1, true) ~= nil, why)
  assert(table.concat(one:paths(), ",") == "a.css")
end

local function test_under_refuses_a_prefix_without_a_slash_and_layered_says_why_the_last_missed()
  local source = Assets.memory({ ["images/a.png"] = "a" })
  local ok, why = pcall(Assets.under, source, "images")
  assert(not ok and tostring(why):find("does not end in a slash", 1, true) ~= nil, tostring(why))
  assert(assert(Assets.under(source, ""):get("images/a.png")).data == "a")
  local _, missed = Assets.layered({ source, source }):get("/abs")
  assert(missed:find("absolute", 1, true) ~= nil, missed)
  local dynamic = Assets.layered({ source, { get = source.get, paths = source.paths,
    dynamic = function(_self: Assets.Source): boolean return true end } })
  assert(dynamic:dynamic() and not Assets.layered({ source }):dynamic())
end
