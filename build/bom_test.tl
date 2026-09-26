local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local bom = require("build.bom")
local invoke = require("build.invoke")
local schema = require("build.schema")
local type Declared = require("build.inputs").Declared

--- What the bill of materials describes: every vendored tree, the patches
--- to it and the pins it came by.
local _inputs: Declared = { reads = { "bin/zig.pin", "build/bom/", "patch/", "vendor/" } }

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

--- Every key but `notice` is read once, the first line winning, as
--- `bin/vendor` reads a PIN: a second `url` names no other archive.
local function test_the_first_line_naming_a_key_wins()
  local component = assert(bom.parse("a", "version 1\nurl first\nurl second\n" ..
    "license MIT\nlicense GPL-3.0\nnotice A\nnotice B\n"))
  assert(component.url == "first" and component.license == "MIT")
  assert(#component.notices == 2)
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
  assert(Fs.write(tmp .. "/patch/zlib/.01-fix.txt.swp", "an editor's"))
  assert(Fs.write(tmp .. "/patch/zlib/README", "not a patch"))
  assert(Fs.mkdirs(tmp .. "/vendor/roots"))
  assert(Fs.write(tmp .. "/vendor/roots/PIN", "version 7\nurl https://roots.example/r.pem\n" ..
    "kind data\nlicense MPL-2.0\n"))
  assert(Fs.write(tmp .. "/build/bom/libc.pin", "version 2\nurl https://libc.example/\n" ..
    "license MIT\nnotice libc.COPYRIGHT\n"))
  assert(Fs.write(tmp .. "/build/bom/libc.COPYRIGHT", "(C) libc\r\nMIT"))
  local db = database()
  assert(bom.fill(db, tmp, "main."))
  local rows = assert(bom.rows(db))
  assert(#rows == 3, "a directory with no PIN is no component")
  assert(rows[1].name == "libc" and rows[1].sha256 == "" and rows[1].patches == "")
  assert(rows[2].name == "roots" and rows[2].kind == "data")
  assert(rows[3].name == "zlib" and rows[3].sha256 == "00ff")
  assert(rows[3].patches == "patch/zlib/01-fix.txt " .. Hash.hex_sha256("a patch"),
    "only a patch record counts, not a file beside one: " .. rows[3].patches)
  local notices = assert(bom.notices(db))
  assert(notices:find(" (C) Jean-loup Gailly\n Mark Adler\n", 1, true),
    "a range keeps those lines of the file: " .. notices)
  assert(notices:find("(C) libc\nMIT\n", 1, true),
    "a notice's CRLFs are LFs, and its last line ends: " .. notices)
  assert(notices:find("https://roots.example/r.pem", 1, true),
    "a component with no notice still names where its source is: " .. notices)
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

local function test_two_records_may_not_name_one_component(tmp: string)
  assert(Fs.mkdirs(tmp .. "/vendor/zlib"))
  assert(Fs.mkdirs(tmp .. "/build/bom"))
  assert(Fs.write(tmp .. "/vendor/zlib/PIN", "version 1\nurl u\nlicense Zlib\n"))
  assert(Fs.write(tmp .. "/build/bom/zlib.pin", "version 2\nurl v\nlicense Zlib\n"))
  local db = database()
  local filled, trouble = bom.fill(db, tmp, "main.")
  assert(not filled and trouble == "two records name zlib", trouble)
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
  local licenses = zlib.licenses as {{string:any}}
  assert(licenses[1].expression == "Zlib")
  local pedigree = zlib.pedigree as {string:any}
  assert(pedigree.notes == "patched by cosmic:\npatch/zlib/a 01", tostring(pedigree.notes))
  local references = zlib.externalReferences as {{string:any}}
  local hashes = references[1].hashes as {{string:any}}
  assert(hashes[1].alg == "SHA-256" and hashes[1].content == "00ff")
  local roots = components[2]
  assert(roots.type == "data" and roots.pedigree == nil)
  local roots_references = roots.externalReferences as {{string:any}}
  assert(roots_references[1].hashes == nil, "no digest is named when the record has none")
end

-- TODO: hold build/bom/musl.pin's version and both notices copied
-- beside it to the pinned zig's own lib/libc/musl and LICENSE, once a
-- test can find the pinned zig install: only `build/zig.tl`, run
-- standalone by `bin/zig`, knows where it unpacked it.

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

--- `cosmic bom` answers from the running binary's own rows: each
--- component a line, `--json` a document naming the same components,
--- and `--licenses` every notice.
local function test_the_verb_prints_the_binary_s_own_rows(tmp: string)
  local listed = invoke.run({ "bom" }, { cwd = tmp })
  assert(listed.code == 0, listed.stderr)
  assert(listed.stdout:find("\nlua %S+  MIT\n") or listed.stdout:find("^lua %S+  MIT\n"),
    listed.stdout)
  -- Data is what `cosmic refresh` updates, and the line says so.
  assert(listed.stdout:find("\ntzdata %S+  %S+  %(data: `cosmic refresh` updates it%)\n"), listed.stdout)
  assert(listed.stdout:find("\ncacert %S+  %S+  %(data: `cosmic refresh` updates it%)\n"), listed.stdout)
  local path = tmp .. "/bom.json"
  local written = invoke.run({ "bom", "--json", path }, { cwd = tmp })
  assert(written.code == 0, written.stderr)
  local decoded = assert(Json.decode_object((assert(Fs.read(path)))))
  local names: {string:boolean} = {}
  for _, component in ipairs(decoded.components as {{string:any}}) do
    names[tostring(component.name)] = true
  end
  assert(names["lua"] and names["curl"] and names["musl"], "the document names the components")
  local notices = invoke.run({ "bom", "--licenses" }, { cwd = tmp })
  assert(notices.code == 0, notices.stderr)
  assert(notices.stdout:find("Lua.org, PUC-Rio", 1, true), "lua's notice is printed")
  assert(notices.stdout:find("== sqlite", 1, true), "a component with no notice is named")
end

--- The words of an SPDX expression that name a license.
local function ids_of(expression: string): {string:boolean}
  local ids: {string:boolean} = {}
  for word in expression:gmatch("[^%s()]+") do
    if word ~= "AND" and word ~= "OR" and word ~= "WITH" then
      ids[word] = true
    end
  end
  return ids
end

--- Every `SPDX-License-Identifier` tag a vendored tree's own files
--- carry names a license its PIN's expression names too: a file under
--- another license than the tree's is one whose notice the tree's own
--- license file does not hold. A file whose text is under a license its
--- tag does not name, or that has no tag -- c-ares' ISC files tagged
--- MIT, Apple's dnsinfo.h -- is beyond this, and named in its PIN by
--- reading it.
local function test_every_license_a_vendored_file_is_tagged_with_is_named()
  local root = assert(Fs.absolute("."))
  for _, name in ipairs((assert(Fs.list(root .. "/vendor")))) do
    local directory = root .. "/vendor/" .. name
    local pin = Fs.read(directory .. "/PIN")
    if pin ~= nil then
      local named = ids_of(assert(bom.parse(name, pin)).license)
      local files = assert(Fs.walk(directory))
      for _, file in ipairs(files) do
        if file ~= "PIN" then
          local data = assert(Fs.read(directory .. "/" .. file))
          for tag in data:gmatch("SPDX%-License%-Identifier:%s*([^\n*]+)") do
            for id in pairs(ids_of(tag)) do
              assert(named[id], "vendor/" .. name .. "/" .. file .. " is under " .. id ..
                ", which vendor/" .. name .. "/PIN's license does not name")
            end
          end
        end
      end
    end
  end
end
