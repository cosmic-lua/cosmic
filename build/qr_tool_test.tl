--- `cosmic qr` run as this program: real standard input and output, no
--- summary, and the exit status. These start this program, so they need
--- `tool`; what each option draws is in build/qr_test.tl.

local Fs = require("cosmic.fs")
local Qr = require("cosmic.qr")
local Test = require("cosmic.test")
local tool_fixture = require("build.tool_fixture")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function test_it_prints_the_code_and_no_summary(tmp: string)
  local want = Qr.text((assert(Qr.encode("https://example.com/"))))
  local ran = tool_fixture.cosmic(tmp, { "qr", "https://example.com/" })
  assert(ran.code == 0 and ran.err == "" and ran.out == want, ran.out .. ran.err)
  local piped = tool_fixture.cosmic(tmp, { "qr" }, "https://example.com/\n")
  assert(piped.code == 0 and piped.err == "" and piped.out == want, piped.out .. piped.err)
end

local function test_it_writes_an_svg_file(tmp: string)
  local ran = tool_fixture.cosmic(tmp, { "qr", "--svg", "code.svg", "x" })
  assert(ran.code == 0 and ran.out == "" and ran.err == "", ran.out .. ran.err)
  assert(assert(Fs.read(tmp .. "/code.svg")) == Qr.svg((assert(Qr.encode("x")))) .. "\n")
  local read = tool_fixture.cosmic(tmp, { "qr", "read", "code.svg" })
  assert(read.code == 0 and read.out == "x\n" and read.err == "", read.out .. read.err)
end

local function test_refusals_are_exit_2_and_too_large_exit_1_with_no_summary(tmp: string)
  local refused = tool_fixture.cosmic(tmp, { "qr", "--level", "X", "x" })
  assert(refused.code == 2 and refused.out == "", refused.out)
  assert(refused.err:find("cosmic: qr: --level is L, M, Q or H, not X", 1, true), refused.err)
  assert(not refused.err:find("qr: FAIL", 1, true), refused.err)
  local large = tool_fixture.cosmic(tmp, { "qr", "--max-version", "1", string.rep("a", 15) })
  assert(large.code == 1 and large.out == "", large.out)
end

local function test_a_code_piped_into_read_prints_its_text(tmp: string)
  local drawn = tool_fixture.cosmic(tmp, { "qr", "https://example.com/" })
  local read = tool_fixture.cosmic(tmp, { "qr", "read" }, drawn.out)
  assert(read.code == 0 and read.out == "https://example.com/\n" and read.err == "", read.out .. read.err)
end

local function test_a_code_copied_indented_and_in_color_reads_back(tmp: string)
  local drawn = tool_fixture.cosmic(tmp, { "qr", "--color", "https://example.com/" })
  assert(drawn.code == 0 and drawn.out:find("\27[30;107m", 1, true) ~= nil, drawn.out .. drawn.err)
  local indented = drawn.out:gsub("[^\n]+", "    %0")
  local read = tool_fixture.cosmic(tmp, { "qr", "read" }, indented)
  assert(read.code == 0 and read.out == "https://example.com/\n" and read.err == "", read.out .. read.err)
end

--- Through the binary: `--read` points at `read`, a text after `--` may start with "read", and `read` has a help
--- page of its own.
local function test_read_is_a_command_and_read_as_text_follows_two_dashes(tmp: string)
  local moved = tool_fixture.cosmic(tmp, { "qr", "--read" }, "")
  assert(moved.code == 2 and moved.err:find("no such option: --read; `cosmic qr read [file|-]` reads a code back", 1, true) ~= nil,
    moved.err)
  local drawn = tool_fixture.cosmic(tmp, { "qr", "--", "read", "me" })
  assert(drawn.code == 0, drawn.err)
  local back = tool_fixture.cosmic(tmp, { "qr", "read" }, drawn.out)
  assert(back.code == 0 and back.out == "read me\n", back.out .. back.err)
  local help = tool_fixture.cosmic(tmp, { "help", "qr", "read" })
  assert(help.code == 0 and help.out:find("usage: cosmic qr read [file|-]\n", 1, true) == 1, help.out)
end

local function test_help_names_the_verb_and_its_options(tmp: string)
  local ran = tool_fixture.cosmic(tmp, { "qr", "--help" })
  assert(ran.code == 0, ran.err)
  for _, word in ipairs({ "cosmic qr", "--svg", "--invert", "--ascii", "--color", "--border", "--level", "--max-version", "read [file|-]" }) do
    assert(ran.out:find(word, 1, true), "the help does not name " .. word)
  end
end
