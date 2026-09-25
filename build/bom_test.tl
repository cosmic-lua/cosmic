local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local bom = require("build.bom")
local schema = require("build.schema")

--- An empty database of the shipped shape.
local function database(): Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    assert(db:exec(statement))
  end
  return db
end

local function test_a_record_names_its_license()
  local component = assert(bom.parse("lua", table.concat({
    "version 5.5.1",
    "url https://www.lua.org/ftp/lua-5.5.1.tar.gz",
    "sha256 ABC",
    "strip lua-5.5.1/",
    "keep src/*.c",
    "license MIT AND APSL-2.0",
    "notice LICENSE",
    "notice src/lua.h:524-543",
  }, "\n")))
  assert(component.license == "MIT AND APSL-2.0", component.license)
  assert(component.kind == "library")
  assert(component.sha256 == "abc", "a digest is kept in lower case")
  assert(#component.notices == 2)
  assert(component.notices[1].file == "LICENSE" and component.notices[1].first == nil)
  assert(component.notices[2].file == "src/lua.h" and component.notices[2].first == 524 and
    component.notices[2].last == 543)
end

local function test_a_record_without_a_license_is_refused()
  local component, trouble = bom.parse("zlib", "version 1.3\nurl https://zlib.net/\n")
  assert(component == nil and trouble == "zlib: its record names no license", trouble)
end

local function test_a_notice_range_must_hold_a_line()
  local _, backwards = bom.parse("a", "version 1\nurl u\nlicense MIT\nnotice f:9-3\n")
  assert(backwards:find("the range is empty", 1, true), backwards)
  local _, half = bom.parse("a", "version 1\nurl u\nlicense MIT\nnotice f:9\n")
  assert(half:find("file:first-last", 1, true), half)
  local _, kind = bom.parse("a", "version 1\nurl u\nlicense MIT\nkind tool\n")
  assert(kind:find("neither library nor data", 1, true), kind)
end

local function test_fill_reads_every_record_and_its_notices(tmp: string)
  assert(Fs.mkdirs(tmp .. "/vendor/zlib"))
  assert(Fs.mkdirs(tmp .. "/vendor/unpinned"))
  assert(Fs.mkdirs(tmp .. "/build/bom"))
  assert(Fs.mkdirs(tmp .. "/patch/zlib"))
  assert(Fs.write(tmp .. "/vendor/zlib/PIN", "version 1.3\nurl https://zlib.net/z.tar.gz\n" ..
    "sha256 00ff\nlicense Zlib\nnotice zlib.h:2-3\n"))
  assert(Fs.write(tmp .. "/vendor/zlib/zlib.h", "/*\n (C) Jean-loup Gailly\n Mark Adler\n*/\n"))
  assert(Fs.write(tmp .. "/patch/zlib/01-fix.txt", "a patch"))
  assert(Fs.write(tmp .. "/build/bom/libc.pin", "version 2\nurl https://libc.example/\n" ..
    "license MIT\nnotice libc.COPYRIGHT\n"))
  assert(Fs.write(tmp .. "/build/bom/libc.COPYRIGHT", "(C) libc\n"))
  local db = database()
  assert(bom.fill(db, tmp, "main."))
  local rows = assert(bom.rows(db))
  assert(#rows == 2, "a directory with no PIN is no component")
  assert(rows[1].name == "libc" and rows[1].sha256 == "" and rows[1].patches == "")
  assert(rows[2].name == "zlib" and rows[2].sha256 == "00ff")
  assert(rows[2].patches == "patch/zlib/01-fix.txt " .. Hash.hex_sha256("a patch"),
    rows[2].patches)
  local lines = bom.lines(rows)
  assert(lines[2] == "zlib 1.3  Zlib  (1 patch)", lines[2])
  local notices = assert(bom.notices(db))
  assert(notices == "== libc 2 (MIT): libc.COPYRIGHT\n\n(C) libc\n\n" ..
    "== zlib 1.3 (Zlib): zlib.h\n\n (C) Jean-loup Gailly\n Mark Adler\n", notices)
  assert(db:close())
end

local function test_fill_refuses_a_notice_past_the_file_s_end(tmp: string)
  assert(Fs.mkdirs(tmp .. "/vendor/zlib"))
  assert(Fs.mkdirs(tmp .. "/build/bom"))
  assert(Fs.write(tmp .. "/vendor/zlib/PIN", "version 1\nurl u\nlicense Zlib\nnotice zlib.h:2-9\n"))
  assert(Fs.write(tmp .. "/vendor/zlib/zlib.h", "one\ntwo\n"))
  local db = database()
  local filled, trouble = bom.fill(db, tmp, "main.")
  assert(not filled and trouble:find("has 2 lines, not 9", 1, true), trouble)
  assert(db:close())
end

local function test_the_json_is_a_cyclonedx_document()
  local document = assert(bom.cyclonedx({
    { name = "zlib", kind = "library", version = "1.3", license = "Zlib",
      url = "https://zlib.net/z 1.tar.gz", sha256 = "00ff", patches = "patch/zlib/a 01" },
    { name = "roots", kind = "data", version = "1", license = "MPL-2.0",
      url = "https://example.com/r.pem", sha256 = "", patches = "" },
  }, "cosmic", "abc"))
  local decoded = assert(Json.decode_object(document))
  assert(decoded.bomFormat == "CycloneDX" and decoded.specVersion == "1.6")
  local components = decoded.components as {{string:any}}
  local zlib = components[1]
  assert(zlib.purl == "pkg:generic/zlib@1.3?download_url=https%3A%2F%2Fzlib.net%2Fz%201.tar.gz",
    tostring(zlib.purl))
  assert(document:find('"expression": "Zlib"', 1, true), document)
  assert(document:find('"notes": "patched by cosmic:\\npatch/zlib/a 01"', 1, true), document)
  assert(document:find('"content": "00ff"', 1, true), document)
  local roots = components[2]
  assert(roots.type == "data" and roots.pedigree == nil)
end

--- The zig record's version is the pinned compiler's, and Lua's notice
--- is the license block at the end of lua.h, not lines a new release
--- moved: each is a fact the record repeats, held to its source here.
local function test_the_tree_s_records_match_what_they_describe()
  local root = assert(Fs.absolute("."))
  local zig_pin = assert(Fs.read(root .. "/bin/zig.pin"))
  local zig = assert(bom.parse("zig", (assert(Fs.read(root .. "/build/bom/zig.pin")))))
  assert(zig_pin:match("^version (%S+)") == zig.version,
    "build/bom/zig.pin names the version bin/zig.pin pins")
  local lua = assert(bom.parse("lua", (assert(Fs.read(root .. "/vendor/lua/PIN")))))
  local db = database()
  assert(bom.fill(db, root, "main."))
  local rows = assert(Sqlite.text_rows(db, "SELECT text FROM notices WHERE component = 'lua'"))
  assert(db:close())
  assert(#lua.notices == 1 and #rows == 1)
  local notice = rows[1][1]
  assert(notice:match("^%* Copyright %(C%) 1994%-%d+ Lua%.org, PUC%-Rio%.\n"), notice)
  assert(notice:match("SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE%.\n$"), notice)
end
