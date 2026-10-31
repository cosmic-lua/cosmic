--- `cosmic lsp`'s framing ([`build.lsp.protocol`]): a message split at
--- every byte, headers it refuses, and a large body.

local Stream = require("cosmic.stream")
local protocol = require("build.lsp.protocol")
local session_fixture = require("build.lsp.session_fixture")

local framed = session_fixture.framed

--- How far a [`trickle`] has read.
local record Read
  mut at: integer
end

--- A stream's `read` that answers one byte of `data` a call, so a
--- message arrives split at every place it can be.
local function trickle(data: string): function(): string?, string
  local read: Read = { at = 1 }
  return function(): string?, string
    if read.at > #data then return nil, "" end
    read.at = read.at + 1
    return data:sub(read.at - 1, read.at - 1), ""
  end
end

local function test_frames_split_at_every_byte()
  local bytes = framed({ '{"a":1}', '{"b":"ü"}' }) .. "Content-Length: 2\r\ncontent-type: x\r\n\r\n{}"
  local frames = protocol.frames_of(trickle(bytes))
  assert(frames:next() == '{"a":1}')
  assert(frames:next() == '{"b":"ü"}')
  assert(frames:next() == "{}")
  local body, trouble = frames:next()
  assert(body == nil and trouble == "", trouble)
end

local function test_frames_refuse_what_is_no_message()
  local cases: {string: string} = {
    ["Content-Type: x\r\n\r\n{}"] = "no Content-Length",
    ["Content-Length: 1x\r\n\r\n{}"] = "no length",
    ["Content-Length: 10\r\n\r\n{}"] = "ended inside a message",
    ["Content-Length: 2\r\n"] = "ended inside a header",
  }
  for bytes, said in pairs(cases) do
    local body, trouble = protocol.frames(Stream.from_string(bytes)):next()
    assert(body == nil, bytes)
    assert(trouble:find(said, 1, true), bytes .. ": " .. trouble)
  end
end

local function test_a_header_too_long_is_refused_whole_or_not()
  local long = "X-Long: " .. ("a"):rep(9000) .. "\r\nContent-Length: 2\r\n\r\n{}"
  local body, trouble = protocol.frames(Stream.from_string(long)):next()
  assert(body == nil, "a header too long is refused")
  assert(trouble:find("a header longer than", 1, true), trouble)
  local endless = "X-Long: " .. ("a"):rep(9000)
  local none, why = protocol.frames_of(trickle(endless)):next()
  assert(none == nil, "a header that never ends is refused")
  assert(why:find("a header longer than", 1, true), why)
end

local function test_a_large_body_arriving_in_pieces_is_whole()
  local text = ("x"):rep(200000)
  local body = '"' .. text .. '"'
  local frames = protocol.frames_of(trickle(protocol.frame(body)))
  assert(frames:next() == body)
end

--- A path is below the root as the system reads both, but for symlinks,
--- which are not asked: their `.` and `..` segments and doubled slashes
--- resolved alike.
local function test_a_path_and_its_root_are_read_alike()
  local record Below
    path: string
    root: string
    below: string
  end
  local cases: {Below} = {
    { path = "/r/a/x.tl", root = "/r", below = "a/x.tl" },
    { path = "/r/a/x.tl", root = "/r/", below = "a/x.tl" },
    { path = "/r//a/./x.tl", root = "/r", below = "a/x.tl" },
    { path = "/r/../r/x.tl", root = "/r", below = "x.tl" },
    { path = "/r/a/x.tl", root = "//r", below = "a/x.tl" },
    { path = "/r/a/x.tl", root = "/./r//", below = "a/x.tl" },
    { path = "/r/x.tl", root = "/s/../r", below = "x.tl" },
    { path = "/r/a/../x.tl", root = "/r", below = "x.tl" },
  }
  for _, case in ipairs(cases) do
    local path, root = case.path, case.root
    local got = protocol.below(path, root)
    assert(got == case.below, path .. " below " .. root .. ": " .. tostring(got))
  end
  for _, outside in ipairs({ { "/r/../x.tl", "/r" }, { "/r", "/r" }, { "/r/.", "/r" },
      { "/rs/x.tl", "/r" }, { "/r/a/../../r2/x.tl", "/r" } }) do
    local path, root = assert(outside[1]), assert(outside[2])
    local got = protocol.below(path, root)
    assert(got == nil, path .. " below " .. root .. ": " .. tostring(got))
  end
end
