--- The mirror task's hidden API test: eval/check/grade.tl runs it
--- against a copy of a solver's project, never shown to the solver.
local Archive = require("cosmic.archive")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local mirror = require("mirror")

local FILES <const>: {string: string} = {
  ["a.txt"] = "alpha\n",
  ["sub/b.bin"] = "\0\1\2\255",
  ["sub/deep/c.txt"] = "charlie\n",
}

--- The same three files as a directory, a tar, a tar.gz and a zip,
--- the zip with no entries for its directories.
local function sources(dir: string): {string}
  for path, data in pairs(FILES) do
    assert(Fs.mkdirs((dir .. "/site/" .. path):match("^(.*)/[^/]*$")))
    assert(Fs.write(dir .. "/site/" .. path, data))
  end
  local paths = { dir .. "/site" }
  for _, ext in ipairs({ "tar", "tar.gz", "zip" }) do
    local path = dir .. "/site." .. ext
    local writer = assert(Archive.create(path))
    if ext ~= "zip" then
      assert(writer:add_dir("sub"))
      assert(writer:add_dir("sub/deep"))
    end
    for _, name in ipairs({ "a.txt", "sub/b.bin", "sub/deep/c.txt" }) do
      assert(writer:add_file(name, FILES[name]))
    end
    assert(writer:close())
    paths[#paths + 1] = path
  end
  return paths
end

local function test_every_source_stats_lists_and_reads_alike(dir: string)
  for _, path in ipairs(sources(dir)) do
    local source, why = mirror.open(path)
    assert(source ~= nil, path .. ": " .. tostring(why))
    local src: mirror.Source = source
    local top = assert(src:stat(""), path .. ": stat of the top")
    assert(top.kind == "dir", path .. ": the top is a " .. tostring(top.kind))
    local a: mirror.Info = assert(src:stat("a.txt"), path .. ": stat a.txt")
    local kind: mirror.Kind = a.kind
    assert(kind == "file" and a.size == 6, path .. ": a.txt is " .. tostring(kind) .. " " ..
        tostring(a.size))
    local sub = assert(src:stat("sub"), path .. ": stat sub")
    assert(sub.kind == "dir" and sub.size == 0, path .. ": sub")
    assert(src:stat("missing") == nil, path .. ": stat of nothing")
    assert(table.concat(assert(src:list("")), ",") == "a.txt,sub", path .. ": list of the top")
    assert(table.concat(assert(src:list("sub")), ",") == "b.bin,deep", path .. ": list of sub")
    assert(src:list("a.txt") == nil, path .. ": list of a file")
    assert(src:read("sub/b.bin") == FILES["sub/b.bin"], path .. ": read sub/b.bin")
    assert(src:read("sub/deep/c.txt") == FILES["sub/deep/c.txt"], path .. ": read c.txt")
    assert(src:read("sub") == nil, path .. ": read of a directory")
  end
end

local function test_a_path_with_dots_or_slashes_names_nothing(dir: string)
  assert(Fs.write(dir .. "/secret.txt", "secret\n"))
  for _, path in ipairs(sources(dir)) do
    local src = assert(mirror.open(path))
    for _, bad in ipairs({ "../secret.txt", "sub/../a.txt", "./a.txt", "/a.txt", "sub//b.bin",
        "a.txt/", ".." }) do
      assert(src:read(bad) == nil, path .. ": read of " .. bad)
      assert(src:stat(bad) == nil, path .. ": stat of " .. bad)
    end
  end
end

--- One ustar header and body: a file at `name` holding `data`.
local function ustar(name: string, data: string): string
  local function padded(text: string, width: integer): string
    return text .. string.rep("\0", width - #text)
  end
  local function octal(n: integer, width: integer): string
    return padded(string.format("%0" .. (width - 1) .. "o", n), width)
  end
  local head = padded(name, 100) .. octal(420, 8) .. octal(0, 8) .. octal(0, 8) ..
    octal(#data, 12) .. octal(0, 12) .. "        " .. "0" .. padded("", 100) ..
    "ustar\0" .. "00" .. padded("", 32) .. padded("", 32) .. octal(0, 8) .. octal(0, 8) ..
    padded("", 155)
  head = padded(head, 512)
  local sum = 0
  for i = 1, #head do
    sum = sum + head:byte(i)
  end
  head = head:sub(1, 148) .. string.format("%06o\0 ", sum) .. head:sub(157)
  return head .. data .. string.rep("\0", (512 - #data % 512) % 512)
end

local function test_open_refuses_what_is_no_source(dir: string)
  assert(Fs.write(dir .. "/evil.tar", ustar("ok.txt", "fine\n") ..
      ustar("../evil.txt", "escaped\n") .. string.rep("\0", 1024)))
  assert(Fs.write(dir .. "/rooted.tar", ustar("/etc/x.txt", "x\n") .. string.rep("\0", 1024)))
  assert(Fs.write(dir .. "/notes.rar", "not an archive"))
  assert(Fs.write(dir .. "/junk.zip", "not a zip at all"))
  for _, name in ipairs({ "evil.tar", "rooted.tar", "notes.rar", "junk.zip", "missing" }) do
    local source, why = mirror.open(dir .. "/" .. name)
    assert(source == nil, name .. " opened")
    assert(why ~= nil and why ~= "", name .. ": no reason")
  end
  assert(Fs.write(dir .. "/dotted.tar", ustar("./top.txt", "top\n") .. string.rep("\0", 1024)))
  local dotted = assert(mirror.open(dir .. "/dotted.tar"))
  assert(dotted:read("top.txt") == "top\n", "./top.txt is not served as top.txt")
end

--- A source of the test's own, held in memory: any mirror.Source is
--- listed alike.
local record Memory is mirror.Source
  files: {string: string}
end

function Memory:stat(path: string): mirror.Info | nil, string
  if self.files[path] ~= nil then
    return { kind = "file", size = #self.files[path] }
  elseif path == "" or path == "sub" then
    return { kind = "dir", size = 0 }
  end
  return nil, "no " .. path
end

function Memory:list(path: string): {string} | nil, string
  if path == "" then return { "sub", "z.txt" } end
  if path == "sub" then return { "y.txt" } end
  return nil, "not a directory: " .. path
end

function Memory:read(path: string): string | nil, string
  local data = self.files[path]
  if data == nil then return nil, "no " .. path end
  return data
end

local function test_a_listing_of_any_source_is_what_serve_answers()
  local memory: Memory = setmetatable({ files = { ["z.txt"] = "zulu\n", ["sub/y.txt"] = "y" } },
    { __index = Memory })
  local text, why = mirror.listing(memory, "")
  assert(text ~= nil, why)
  local got = Json.decode(text)
  assert(got is {any}, text)
  assert(#got == 2, text)
  local dir_entry, file_entry = got[1] as {string: any}, got[2] as {string: any}
  assert(dir_entry.name == "sub" and dir_entry.type == "dir", text)
  assert(file_entry.name == "z.txt" and file_entry.type == "file" and file_entry.size == 5 and
      file_entry.sha256 == Hash.hex_sha256("zulu\n"), text)
  local inner = assert(mirror.listing(memory, "sub"))
  assert(inner:find("y.txt", 1, true), inner)
end
