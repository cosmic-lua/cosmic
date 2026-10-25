local Assets = require("cosmic.web.assets")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Store = require("cosmic.store")
local Test = require("cosmic.test")

Test.policy{}

--- The message of the error `fn` raises; fails where it raises none.
local function raised(fn: function()): string
  local ok, err = pcall(function(): any
    fn()
    return nil
  end)
  assert(not ok, "expected a raise")
  return tostring(err)
end

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
    assert(asset == nil and why:find("no such asset", 1, true), path)
  end
end

local function test_memory_refuses_a_key_that_is_no_relative_path()
  assert(raised(function() Assets.memory({ ["/abs"] = "x" }) end):find("absolute", 1, true))
  assert(raised(function() Assets.memory({ ["../up"] = "x" }) end):find("'..'", 1, true))
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
  assert(asset == nil and why:find("16 MiB", 1, true))
end

--- Calls `fn` as a program whose database records `main` as its main
--- module ("" for the tool, which records none).
local function as_program(main: string, fn: function())
  local real = Store.meta
  Store.meta = function(key: string): string?
    if key == "main" then return main end
    return real(key)
  end
  local ok, err = pcall(function(): any
    fn()
    return nil
  end)
  Store.meta = real
  assert(ok, tostring(err))
end

local function test_default_reads_the_directory_in_dev_and_for_a_program_not_built(tmp: string)
  assert(Fs.write(tmp .. "/a.txt", "x"))
  local lines: {string} = {}
  local logged = function(text: string) lines[#lines + 1] = text end
  as_program("", function()
    local dev = Assets.default({ dev = true, root = tmp, log = logged })
    assert(dev:dynamic() and #lines == 0 and assert(dev:get("a.txt")).data == "x")
    local fallback = Assets.default({ root = tmp, log = logged })
    assert(fallback:dynamic() and #lines == 1 and lines[1]:find("not a built program", 1, true))
    assert(assert(fallback:get("a.txt")).data == "x")
  end)
end

local function test_default_of_a_built_program_serves_only_what_it_carries(tmp: string)
  assert(Fs.write(tmp .. "/a.txt", "x"))
  local lines: {string} = {}
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

local function test_directory_refuses_a_hidden_file_as_paths_does(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root/.git"))
  assert(Fs.write(tmp .. "/root/.env", "SECRET"))
  assert(Fs.write(tmp .. "/root/.git/config", "SECRET"))
  assert(Fs.write(tmp .. "/root/a.txt", "x"))
  local source = Assets.directory(tmp .. "/root")
  assert(source:get("a.txt") ~= nil)
  for _, path in ipairs({ ".env", ".git/config" }) do
    local asset, why = source:get(path)
    assert(asset == nil and why:find("hidden", 1, true), path)
  end
end

local function test_directory_of_the_filesystem_root_serves_its_files(tmp: string)
  assert(Fs.write(tmp .. "/f.txt", "inside"))
  local real = assert(Fs.absolute(tmp))
  local asset, why = Assets.directory("/"):get(real:sub(2) .. "/f.txt")
  assert(asset ~= nil and asset.data == "inside", why)
end
