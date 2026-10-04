--- `cosmic codec` run as this program: real standard input and output,
--- no verdict line, exit 0 or 2, and a write to a closed descriptor.
--- These start this program, so they need `tool`; the coders themselves
--- are in `codec_test.tl`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local confine = require("build.confine")
local this_program = require("build.this_program")
local Clock = require("cosmic.clock")

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

local function test_it_reads_standard_input_and_prints_no_verdict(tmp: string)
  local enc = cosmic(tmp, { "codec", "base64" }, "foobar")
  assert(enc.code == 0, enc.err)
  assert(enc.out == "Zm9vYmFy\n" and enc.err == "", enc.out .. enc.err)
  local dash = cosmic(tmp, { "codec", "hex", "-" }, "\0\xff")
  assert(dash.code == 0 and dash.out == "00ff\n", dash.out)
  local dec = cosmic(tmp, { "codec", "base64url", "-d" }, "AAH7__4A\n")
  assert(dec.code == 0 and dec.out == "\0\1\xfb\xff\xfe\0" and dec.err == "", dec.err)
end

local function test_a_file_is_read_and_a_bad_text_exits_2(tmp: string)
  local path = tmp .. "/in.txt"
  assert(Fs.write(path, "66 6f\n6f\n"))
  local ok = cosmic(tmp, { "codec", "hex", "-d", path })
  assert(ok.code == 0 and ok.out == "foo" and ok.err == "", ok.err)
  local bad = cosmic(tmp, { "codec", "hex", "-d" }, "66zz")
  assert(bad.code == 2 and bad.out == "", bad.out)
  assert(bad.err:find("cosmic: codec: standard input: byte 0x7a at offset 2", 1, true), bad.err)
  assert(not bad.err:find("FAIL", 1, true), bad.err)
  local usage = cosmic(tmp, { "codec", "base32" }, "x")
  assert(usage.code == 2 and usage.out == "" and usage.err:find("no such encoding", 1, true), usage.err)
end

local function test_a_failed_standard_output_write_exits_2(tmp: string)
  -- /dev/full, where a write fails with ENOSPC, is Linux's, and every
  -- worker there is given it (build.confine's `runtime_paths`): one
  -- without it is skipped, and elsewhere there is nothing to check.
  if Fs.stat("/dev/full") == nil then
    if confine.sandbox_platform() then Test.skip("this worker has no /dev/full") end
    return
  end
  local full = assert(Fs.open_write("/dev/full"))
  local started = this_program.program({ "codec", "hex" }, {
    cwd = tmp, stdout = full, stderr = "capture", input = "abc", timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(Fs.close(full))
  assert(result.code == 2, tostring(result.code))
  assert((result.stderr or ""):find("cosmic: codec: standard output: ", 1, true), result.stderr)
end

local function test_help_names_the_verb_and_its_options(tmp: string)
  local ran = cosmic(tmp, { "codec", "--help" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("cosmic codec", 1, true) and ran.out:find("--wrap", 1, true), ran.out)
end
