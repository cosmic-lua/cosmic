--- The case of build/version_test.tl that reads this program: `cosmic
--- --version` names the build by the digest its release records, the
--- SHA-256 of the file the binary runs from. It declares `tool` because
--- it reads this program's file. `cosmic help`'s description of it,
--- which reads the store, is in build/version_store_test.tl.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local invoke = require("build.invoke")

--- The tool itself, whose digest the version is.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function test_version_is_the_digest_of_the_binarys_own_file(tmp: string)
  local path = assert(Proc.executable())
  local expected = "cosmic " .. Hash.hex_sha256((assert(Fs.read(path)))) .. "\n"
  local result = invoke.run({ "--version" }, { cwd = tmp })
  assert(result.code == 0, result.stderr)
  assert(result.stdout == expected, result.stdout)
  assert(result.stderr == "", result.stderr)
end

--- The key `--version` keeps a digest under: the file's device, inode,
--- size, mtime and ctime, as build/dispatch.tl's `file_digest` writes it.
local function key_of(path: string): string
  local st = assert(Fs.stat(path))
  return ("%d %d %d %d.%09d %d.%09d"):format(st.dev, st.ino, st.size,
    st.mtime, st.mtime_ns, st.ctime, st.ctime_ns)
end

local function test_version_keeps_the_digest_and_reads_it_back(tmp: string)
  local path = assert(Proc.executable())
  local env = { XDG_CACHE_HOME = tmp .. "/cache" }
  local real = Hash.hex_sha256((assert(Fs.read(path))))
  local first = invoke.run({ "--version" }, { cwd = tmp, env = env })
  assert(first.code == 0 and first.stdout == "cosmic " .. real .. "\n", first.stderr)
  local entry = tmp .. "/cache/cosmic/version/digest"
  assert(Fs.read(entry)! == key_of(path) .. "\t" .. real .. "\n")
  -- A kept digest for this file's key is answered with no hashing: a
  -- planted one shows it is read.
  local planted = ("ab"):rep(32)
  assert(Fs.write(entry, key_of(path) .. "\t" .. planted .. "\n"))
  local second = invoke.run({ "--version" }, { cwd = tmp, env = env })
  assert(second.stdout == "cosmic " .. planted .. "\n", second.stdout)
end

local function test_version_hashes_again_for_another_files_key(tmp: string)
  local path = assert(Proc.executable())
  local env = { XDG_CACHE_HOME = tmp .. "/cache" }
  local real = Hash.hex_sha256((assert(Fs.read(path))))
  assert(Fs.mkdirs(tmp .. "/cache/cosmic/version", 0x1c0))
  local entry = tmp .. "/cache/cosmic/version/digest"
  assert(Fs.write(entry, "1 2 3 4.000000000 5.000000000\t" .. ("ab"):rep(32) .. "\n"))
  local result = invoke.run({ "--version" }, { cwd = tmp, env = env })
  assert(result.stdout == "cosmic " .. real .. "\n", result.stdout)
  assert(Fs.read(entry)! == key_of(path) .. "\t" .. real .. "\n")
end

local function test_version_hashes_again_for_a_malformed_entry(tmp: string)
  local path = assert(Proc.executable())
  local env = { XDG_CACHE_HOME = tmp .. "/cache" }
  local real = Hash.hex_sha256((assert(Fs.read(path))))
  assert(Fs.mkdirs(tmp .. "/cache/cosmic/version", 0x1c0))
  local entry = tmp .. "/cache/cosmic/version/digest"
  for _, kept in ipairs({
      key_of(path) .. "\t" .. ("a"):rep(63) .. "\n",
      key_of(path) .. " " .. ("ab"):rep(32) .. "\n",
      key_of(path) .. "\t" .. ("ab"):rep(32),
  }) do
    assert(Fs.write(entry, kept))
    local result = invoke.run({ "--version" }, { cwd = tmp, env = env })
    assert(result.stdout == "cosmic " .. real .. "\n", result.stdout)
    assert(Fs.read(entry)! == key_of(path) .. "\t" .. real .. "\n")
  end
end

local function test_version_hashes_where_no_cache_can_be_made(tmp: string)
  local path = assert(Proc.executable())
  local real = Hash.hex_sha256((assert(Fs.read(path))))
  -- A relative XDG_CACHE_HOME and no HOME: no cache directory at all.
  local result = invoke.run({ "--version" }, { cwd = tmp, env = { XDG_CACHE_HOME = "rel" } })
  assert(result.code == 0 and result.stderr == "", result.stderr)
  assert(result.stdout == "cosmic " .. real .. "\n", result.stdout)
end
