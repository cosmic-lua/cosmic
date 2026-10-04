--- `cosmic hash` run as this program: real standard input, the absence of
--- a verdict line, its exit statuses, and a file streamed from disk.
--- These start this program, so they need `tool`; the digests
--- themselves are in `hash_test.tl`.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start.
Test.needs{ tool = true }

local record Ran
  code: integer
  out: string
  err: string
end

local function cosmic(dir: string, words: {string}, input?: string): Ran
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", input = input,
    timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code, out = result.stdout or "", err = result.stderr or "" }
end

local ABC <const> = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

local function test_it_reads_standard_input_and_prints_no_verdict(tmp: string)
  local ran = cosmic(tmp, { "hash" }, "abc")
  assert(ran.code == 0, ran.err)
  assert(ran.out == ABC .. "  -\n" and ran.err == "", ran.out .. ran.err)
  local dash = cosmic(tmp, { "hash", "--sha1", "-" }, "abc")
  assert(dash.out == "a9993e364706816aba3e25717850c26c9cd0d89d  -\n", dash.out)
end

local function test_check_exits_1_on_a_failure_and_2_on_a_usage_error(tmp: string)
  assert(Fs.write(tmp .. "/a", "abc"))
  assert(Fs.write(tmp .. "/sums", ABC .. "  a\n" .. ABC .. "  b\n"))
  local checked = cosmic(tmp, { "hash", "--check", "sums" })
  assert(checked.code == 1, checked.code)
  assert(checked.out == "a: OK\nb: FAILED open or read\n", checked.out)
  assert(not checked.err:find("hash: FAIL", 1, true), checked.err)
  local usage = cosmic(tmp, { "hash", "--sha1", "--md5", "a" })
  assert(usage.code == 2 and usage.out == "", usage.out)
  assert(not usage.err:find("hash: FAIL", 1, true), usage.err)
end

--- A file of 16 MiB, hashed from disk.
local function test_a_large_file_streams(tmp: string)
  local chunk = string.rep("x", 1 << 20)
  local writer = (assert(Stream.create(tmp .. "/big")))
  for _ = 1, 16 do assert(writer:write(chunk)) end
  assert(writer:close())
  local ran = cosmic(tmp, { "hash", "--md5", "big" })
  assert(ran.code == 0, ran.err)
  local expected = (assert(Stream.hashing("md5")))
  for _ = 1, 16 do assert(expected:write(chunk)) end
  local raw = expected:digest()
  local hex = Codec.hex(raw as string)
  assert(ran.out == hex .. "  big\n", ran.out)
end

--- Help reads the store's docs, which a test not declaring `store` is held
--- from, and one that does runs again on every edit to the tree; so it
--- is here, with the tests that start the program, not in-process.
local function test_help_names_the_verb_and_its_options(tmp: string)
  local ran = cosmic(tmp, { "hash", "--help" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("cosmic hash", 1, true) and ran.out:find("--hmac-file", 1, true), ran.out)
end
