--- `cosmic archive` (build/archive.tl), run in this process with its
--- input and output stood in for: list (text and `--json`, each
--- format, standard input), extract (members, `-C`, `--force`, and the
--- refusals of a path that escapes), create and its round trip. Its
--- archives are built here with the modules' own writers. The exit
--- statuses and the absence of a verdict line, which only a process of
--- its own shows, are in build/archive_tool_test.tl.

local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")
local sys = require("cosmic.sys")
local archive = require("build.archive")

local record Ran
  code: integer
  out: string
  err: string
end

--- One run: `words` after `cosmic archive`, `stdin` standing in for
--- standard input (bytes, or a Reader for input that is not to be held
--- whole), and `out_ok` false for a standard output that fails.
local function run(words: {string}, stdin?: string | Stream.Reader, out_ok?: boolean): Ran
  local argv: {integer:string} = { [0] = "cosmic", [1] = "archive" }
  for index, word in ipairs(words) do argv[index + 1] = word end
  local ran: Ran = { code = -1, out = "", err = "" }
  ran.code = archive.run(argv, {
    out = function(text: string): boolean, string
      if out_ok == false then return false, "no space left" end
      ran.out = ran.out .. text
      return true, ""
    end,
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
    stdin = function(): Stream.Reader | nil, string
      if stdin == nil then return nil, "no standard input in this test" end
      if stdin is string then return Stream.from_string(stdin), "" end
      return stdin as Stream.Reader, ""
    end,
  })
  return ran
end

local record Member
  path: string
  body: string
  link: string
  dir: boolean
end

local function file_member(path: string, body: string): Member
  return { path = path, body = body, link = "", dir = false }
end

local function dir_member(path: string): Member
  return { path = path, body = "", link = "", dir = true }
end

local function link_member(path: string, target: string): Member
  return { path = path, body = "", link = target, dir = false }
end

--- A tar at `path`, gzipped when `gzip`, holding `members`.
local function make_tar(path: string, members: {Member}, gzip?: boolean): string
  local sink = assert(Stream.create(path))
  local w: Tar.Writer
  if gzip then
    w = Tar.writer(Stream.transform_writer(sink, (assert(Compress.deflater("gzip")))))
  else
    w = Tar.writer(sink)
  end
  for _, m in ipairs(members) do
    if m.dir then
      assert(w:add_dir(m.path))
    elseif m.link ~= "" then
      assert(w:add_symlink(m.path, m.link))
    else
      assert(w:add_file(m.path, m.body))
    end
  end
  assert(w:close())
  return path
end

local function make_zip(path: string, members: {Member}): string
  local w = Zip.writer((assert(Stream.create(path))))
  for _, m in ipairs(members) do
    if m.dir then
      assert(w:add_dir(m.path))
    else
      assert(w:add_file(m.path, m.body))
    end
  end
  assert(w:close())
  return path
end

local SAMPLE: {Member} = {
  dir_member("proj"),
  file_member("proj/a.txt", "alpha"),
  file_member("proj/sub/b.txt", "bravo!"),
  file_member("top.txt", "top"),
}

--- Each format's archive of `SAMPLE`, by a name that says nothing
--- about it: the format is read from the bytes.
local function each_format(tmp: string): {string:string}
  return {
    zip = make_zip(tmp .. "/one.bin", SAMPLE),
    tar = make_tar(tmp .. "/two.bin", SAMPLE),
    ["tar.gz"] = make_tar(tmp .. "/three.zip", SAMPLE, true),
  }
end

local function test_list_prints_path_size_mode_and_type_for_each_format(tmp: string)
  for format, path in pairs(each_format(tmp)) do
    local ran = run({ "list", path })
    assert(ran.code == 0 and ran.err == "", format .. ": " .. ran.err)
    local rows: {{string}} = {}
    for line in ran.out:gmatch("[^\n]+") do
      local cells: {string} = {}
      for cell in (line .. "\t"):gmatch("([^\t]*)\t") do cells[#cells + 1] = cell end
      assert(#cells == 4, format .. ": " .. line)
      rows[#rows + 1] = cells
    end
    assert(#rows == 4, format .. ": " .. ran.out)
    assert(rows[1][1] == "proj" or rows[1][1] == "proj/", format .. ": " .. rows[1][1])
    assert(rows[1][4] == "dir", format)
    assert(rows[2][1] == "proj/a.txt" and rows[2][2] == "5" and rows[2][4] == "file",
      format .. ": " .. table.concat(rows[2], "|"))
    assert(rows[3][1] == "proj/sub/b.txt" and rows[3][2] == "6", format)
    assert(rows[4][1] == "top.txt" and rows[4][2] == "3", format)
    assert(rows[4][3]:match("^%d%d%d%d$"), rows[4][3])
  end
end

local function test_list_json_is_an_array_of_objects_for_each_format(tmp: string)
  for format, path in pairs(each_format(tmp)) do
    local ran = run({ "list", "--json", path })
    assert(ran.code == 0 and ran.err == "", format .. ": " .. ran.err)
    local rows = assert(Json.decode(ran.out)) as {{string:any}}
    assert(#rows == 4, format .. ": " .. ran.out)
    assert(rows[2].path == "proj/a.txt" and rows[2].size == 5 and rows[2].type == "file", format)
    assert(rows[2].mode == "0644" and math.type(rows[2].mtime) == "integer", format)
    assert(rows[1].type == "dir", format)
  end
end

local function test_list_json_of_an_empty_archive_is_an_empty_array(tmp: string)
  local path = make_zip(tmp .. "/empty.zip", {})
  local ran = run({ "list", "--json", path })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "[]\n", ran.out)
  assert(run({ "list", path }).out == "")
end

local function test_list_shows_a_symlink_and_escapes_a_name(tmp: string)
  local path = make_tar(tmp .. "/l.tar", { file_member("t.txt", "x"), link_member("ln", "t.txt"),
    file_member("odd\tname\n", "y") })
  local ran = run({ "list", path })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("ln -> t.txt\t0\t", 1, true), ran.out)
  assert(ran.out:find("odd\\tname\\n\t1\t", 1, true), ran.out)
  local json = assert(Json.decode(run({ "list", "--json", path }).out)) as {{string:any}}
  assert(json[2].linkpath == "t.txt" and json[2].type == "symlink")
  assert(json[3].path == "odd\tname\n")
end

local function test_list_reads_standard_input(tmp: string)
  local path = make_tar(tmp .. "/in.tar", SAMPLE, true)
  local bytes = assert(Fs.read(path))
  local ran = run({ "list", "-" }, bytes)
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.out:find("proj/a.txt\t5\t", 1, true), ran.out)
  local json = run({ "list", "--json", "-" }, bytes)
  assert(json.code == 0 and json.out:find('"proj/a.txt"', 1, true), json.out)
end

local function test_list_and_extract_read_a_tgz_and_a_zip_from_standard_input(tmp: string)
  local formats: {string:string} = {
    zip = make_zip(tmp .. "/s.zip", SAMPLE),
    tgz = make_tar(tmp .. "/s.tgz", SAMPLE, true),
    tar = make_tar(tmp .. "/s.tar", SAMPLE),
  }
  for format, path in pairs(formats) do
    local bytes = assert(Fs.read(path))
    local listed = run({ "list", "-" }, bytes)
    assert(listed.code == 0 and listed.err == "", format .. ": " .. listed.err)
    assert(listed.out:find("proj/sub/b.txt\t6\t", 1, true), format .. ": " .. listed.out)
    local dest = tmp .. "/from-" .. format
    local ran = run({ "extract", "-", "-C", dest }, bytes)
    assert(ran.code == 0 and ran.err == "", format .. ": " .. ran.err)
    assert(Fs.read(dest .. "/proj/sub/b.txt") == "bravo!", format)
    assert(Fs.read(dest .. "/top.txt") == "top", format)
  end
end

local function test_list_spools_no_temporary_file_for_a_tar_stream_but_does_for_a_zip(tmp: string)
  local made = 0
  local real_mkdtemp = Fs.mkdtemp
  local patched = Fs as {string:any}
  patched.mkdtemp = function(prefix: string): string | nil, string
    made = made + 1
    return real_mkdtemp(prefix)
  end
  local ok, err = pcall(function(): string
    for _, gzip in ipairs({ false, true }) do
      local bytes = assert(Fs.read(make_tar(tmp .. "/t.tar", SAMPLE, gzip)))
      local ran = run({ "list", "-" }, bytes)
      assert(ran.code == 0 and ran.out:find("top.txt", 1, true), ran.err)
    end
    assert(made == 0, "a tar stream was written to a temporary file")
    local zip = assert(Fs.read(make_zip(tmp .. "/z.zip", SAMPLE)))
    local ran = run({ "list", "-" }, zip)
    assert(ran.code == 0 and ran.out:find("top.txt", 1, true), ran.err)
    assert(made == 1, "a zip needs its file")
    return ""
  end)
  patched.mkdtemp = real_mkdtemp
  assert(ok, err)
end

--- A file of `mib` MiB that deflate cannot shrink, so the .tar.gz
--- holds about as many bytes as it has.
local function write_big_tgz(path: string, mib: integer): integer
  local block: {string} = {}
  for i = 1, 1 << 16 do block[i] = string.char(math.random(0, 255)) end
  local chunk = table.concat(block)
  local rounds = mib * 16
  local left = rounds
  local body: Stream.Reader = {}
  body.read = function(_self: Stream.Reader, _max?: integer): string | nil, string
    if left == 0 then return nil, "" end
    left = left - 1
    return chunk, ""
  end
  body.close = function(_self: Stream.Reader): boolean, string return true, "" end
  local sink = assert(Stream.create(path))
  local w = Tar.writer(Stream.transform_writer(sink, (assert(Compress.deflater("gzip")))))
  assert(w:add_file("big.bin", body, { size = #chunk * rounds }))
  assert(w:close())
  return #chunk * rounds
end

local function test_list_of_a_large_piped_tar_gz_keeps_memory_bounded(tmp: string)
  local total = write_big_tgz(tmp .. "/big.tar.gz", 24)
  collectgarbage()
  collectgarbage()
  local base = collectgarbage("count")
  -- Every read of standard input is preceded by a full collection and a
  -- sample of live memory: a run that held the input whole would show
  -- all of it at once.
  local inner = assert(Stream.open(tmp .. "/big.tar.gz"))
  local reads, peak = 0, 0.0
  local piped: Stream.Reader = {}
  piped.read = function(_self: Stream.Reader, max?: integer): string | nil, string
    collectgarbage()
    peak = math.max(peak, collectgarbage("count"))
    reads = reads + 1
    return inner:read(max)
  end
  piped.close = function(_self: Stream.Reader): boolean, string return inner:close() end
  local ran = run({ "list", "-" }, piped)
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.out:find("big.bin\t" .. total .. "\t", 1, true), ran.out)
  assert(reads >= 100, "standard input was read " .. tostring(reads) .. " times")
  local grown = (peak - base) / 1024
  assert(grown < 4, ("memory grew %.1f MiB listing %d MiB"):format(grown, total >> 20))
end

local function test_an_unknown_format_or_a_missing_file_is_refused(tmp: string)
  local text = tmp .. "/notes.tar.gz"
  assert(Fs.write(text, "just some words, whatever its name says\n"))
  local ran = run({ "list", text })
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("cosmic: archive: ", 1, true) == 1, ran.err)
  assert(ran.err:find("not a recognized archive format", 1, true), ran.err)
  local extracted = run({ "extract", text, "-C", tmp .. "/out" })
  assert(extracted.code == 2 and not Fs.exists(tmp .. "/out/notes"), extracted.err)
  local missing = run({ "list", tmp .. "/nothing.zip" })
  assert(missing.code == 2 and missing.err:find("nothing.zip", 1, true), missing.err)
  local truncated = tmp .. "/cut.tar.gz"
  local whole = assert(Fs.read(make_tar(tmp .. "/whole.tar.gz", SAMPLE, true)))
  assert(Fs.write(truncated, whole:sub(1, #whole - 12)))
  assert(run({ "list", truncated }).code == 2)
end

local function test_extract_unpacks_each_format_into_the_directory(tmp: string)
  for format, path in pairs(each_format(tmp)) do
    local dest = tmp .. "/out-" .. format
    local ran = run({ "extract", path, "-C", dest })
    assert(ran.code == 0 and ran.err == "", format .. ": " .. ran.err)
    assert(Fs.read(dest .. "/proj/a.txt") == "alpha", format)
    assert(Fs.read(dest .. "/proj/sub/b.txt") == "bravo!", format)
    assert(Fs.read(dest .. "/top.txt") == "top", format)
    assert(ran.out:find("proj/a.txt\n", 1, true) and ran.out:find("top.txt\n", 1, true), ran.out)
  end
end

local function test_members_select_a_file_or_everything_under_a_directory(tmp: string)
  local path = make_tar(tmp .. "/m.tar", SAMPLE)
  local one = run({ "extract", path, "-C", tmp .. "/one", "top.txt" })
  assert(one.code == 0, one.err)
  assert(Fs.read(tmp .. "/one/top.txt") == "top")
  assert(not Fs.exists(tmp .. "/one/proj"))
  local tree = run({ "extract", path, "-C", tmp .. "/two", "./proj/", "top.txt" })
  assert(tree.code == 0, tree.err)
  assert(Fs.read(tmp .. "/two/proj/sub/b.txt") == "bravo!")
  assert(Fs.read(tmp .. "/two/top.txt") == "top")
  -- A name is a whole path or a directory, not a prefix of a name.
  local prefix = run({ "extract", path, "-C", tmp .. "/three", "pro" })
  assert(prefix.code == 1 and prefix.err:find("no such member: pro", 1, true), prefix.err)
  assert(not Fs.exists(tmp .. "/three/proj"))
end

local function test_a_missing_member_writes_nothing_and_exits_1(tmp: string)
  local path = make_zip(tmp .. "/z.zip", SAMPLE)
  local ran = run({ "extract", path, "-C", tmp .. "/o", "top.txt", "nope.txt" })
  assert(ran.code == 1 and ran.out == "", ran.out)
  assert(ran.err:find("no such member: nope.txt", 1, true), ran.err)
  assert(not Fs.exists(tmp .. "/o/top.txt"))
end

local function test_extract_reads_standard_input(tmp: string)
  local bytes = assert(Fs.read(make_zip(tmp .. "/s.zip", SAMPLE)))
  local ran = run({ "extract", "-", "-C", tmp .. "/o", "top.txt" }, bytes)
  assert(ran.code == 0, ran.err)
  assert(Fs.read(tmp .. "/o/top.txt") == "top")
end

--- Nothing may land outside `dest`, whatever an archive says: `probe`
--- is where an escape would put a file.
local function refused(path: string, tmp: string, probe: string, why: string)
  local dest = tmp .. "/dest"
  local ran = run({ "extract", "--force", path, "-C", dest })
  assert(ran.code == 2, why .. ": exited " .. ran.code .. " " .. ran.err)
  assert(ran.err:find("cosmic: archive: ", 1, true) == 1, ran.err)
  assert(not Fs.exists(probe), why .. ": wrote " .. probe)
end

local function test_a_dot_dot_member_is_refused_in_tar_and_zip(tmp: string)
  refused(make_tar(tmp .. "/a.tar", { file_member("../escape.txt", "x") }), tmp,
    tmp .. "/escape.txt", "tar ..")
  refused(make_tar(tmp .. "/b.tar", { file_member("sub/../../escape.txt", "x") }), tmp,
    tmp .. "/escape.txt", "tar nested ..")
  refused(make_zip(tmp .. "/c.zip", { file_member("../escape.txt", "x") }), tmp,
    tmp .. "/escape.txt", "zip ..")
end

local function test_an_absolute_member_is_refused(tmp: string)
  local target = tmp .. "/absolute.txt"
  refused(make_tar(tmp .. "/a.tar.gz", { file_member(target, "x") }, true), tmp, target, "tar")
  refused(make_zip(tmp .. "/b.zip", { file_member(target, "x") }), tmp, target, "zip")
end

local function test_a_symlink_out_of_the_target_is_refused(tmp: string)
  refused(make_tar(tmp .. "/a.tar", { link_member("out", "../../elsewhere") }), tmp,
    tmp .. "/dest/out", "a link out")
  refused(make_tar(tmp .. "/b.tar", { link_member("abs", "/etc") }), tmp,
    tmp .. "/dest/abs", "an absolute link")
  -- A file written through a link the archive just made would escape.
  refused(make_tar(tmp .. "/c.tar", { link_member("d", "."), file_member("d/../../up.txt", "x") }),
    tmp, tmp .. "/up.txt", "through a link")
  local through = tmp .. "/through"
  assert(Fs.mkdirs(through))
  local ran = run({ "extract", make_tar(tmp .. "/d.tar",
    { link_member("l", "sub"), file_member("l/f.txt", "x") }), "-C", through })
  assert(not Fs.exists(through .. "/sub/f.txt"), ran.err)
end

local function test_extract_will_not_overwrite_without_force(tmp: string)
  local path = make_tar(tmp .. "/o.tar", SAMPLE)
  local dest = tmp .. "/dest"
  assert(Fs.mkdirs(dest .. "/proj"))
  assert(Fs.write(dest .. "/proj/a.txt", "mine"))
  local ran = run({ "extract", path, "-C", dest })
  assert(ran.code == 1 and ran.out == "", ran.out)
  assert(ran.err:find("would overwrite 1 existing path", 1, true), ran.err)
  assert(ran.err:find("proj/a.txt", 1, true) and ran.err:find("--force", 1, true), ran.err)
  assert(Fs.read(dest .. "/proj/a.txt") == "mine")
  assert(not Fs.exists(dest .. "/top.txt"), "nothing is written on a refusal")
  local forced = run({ "extract", "--force", path, "-C", dest })
  assert(forced.code == 0, forced.err)
  assert(Fs.read(dest .. "/proj/a.txt") == "alpha")
  assert(Fs.read(dest .. "/top.txt") == "top")
  -- Only what a selection would write is looked at.
  local narrow = run({ "extract", path, "-C", dest, "proj/sub" })
  assert(narrow.code == 1 and narrow.err:find("proj/sub/b.txt", 1, true), narrow.err)
  assert(not narrow.err:find("top.txt", 1, true), narrow.err)
end

local function test_a_directory_that_exists_is_not_a_clash(tmp: string)
  local path = make_tar(tmp .. "/d.tar", SAMPLE)
  assert(Fs.mkdirs(tmp .. "/dest/proj/sub"))
  local ran = run({ "extract", path, "-C", tmp .. "/dest", "proj/sub" })
  assert(ran.code == 0, ran.err)
  assert(Fs.read(tmp .. "/dest/proj/sub/b.txt") == "bravo!")
end

--- A tree to pack, under `tmp/src`.
local function make_tree(tmp: string): string
  local src = tmp .. "/src"
  assert(Fs.mkdirs(src .. "/tree/sub"))
  assert(Fs.mkdirs(src .. "/tree/empty"))
  assert(Fs.write(src .. "/tree/z.txt", "zed"))
  assert(Fs.write(src .. "/tree/a.txt", "aye"))
  assert(Fs.write(src .. "/tree/sub/m.txt", "em"))
  assert(Fs.write(src .. "/loose.txt", "loose"))
  return src
end

--- `words` run in `dir`, which `archive` resolves paths against.
local function in_dir(dir: string, words: {string}): Ran
  local here = assert(Fs.absolute("."))
  assert(sys.chdir(dir))
  local ok, ran = pcall(run, words)
  assert(sys.chdir(here))
  assert(ok, ran)
  return ran as Ran
end

local function names(path: string): {string}
  local out: {string} = {}
  for line in run({ "list", path }).out:gmatch("[^\n]+") do
    out[#out + 1] = line:match("^([^\t]*)")
  end
  return out
end

local function test_create_a_zip_sorts_its_entries_and_round_trips(tmp: string)
  local src = make_tree(tmp)
  local ran = in_dir(src, { "create", tmp .. "/out.zip", "tree", "loose.txt" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  local expected = { "loose.txt", "tree", "tree/a.txt", "tree/empty", "tree/sub", "tree/sub/m.txt",
    "tree/z.txt" }
  assert(ran.out == table.concat(expected, "\n") .. "\n", ran.out)
  local listed = names(tmp .. "/out.zip")
  for index, name in ipairs(expected) do
    assert(listed[index] == name or listed[index] == name .. "/", tostring(listed[index]) .. " ~= " .. name)
  end
  local back = run({ "extract", tmp .. "/out.zip", "-C", tmp .. "/back" })
  assert(back.code == 0, back.err)
  assert(Fs.read(tmp .. "/back/tree/a.txt") == "aye")
  assert(Fs.read(tmp .. "/back/tree/sub/m.txt") == "em")
  assert(Fs.read(tmp .. "/back/loose.txt") == "loose")
  assert(Fs.is_dir(tmp .. "/back/tree/empty"))
end

local function test_create_streams_a_large_file_into_a_zip_in_bounded_memory(tmp: string)
  local src = tmp .. "/src"
  assert(Fs.mkdirs(src))
  local line = "streamed into the archive a chunk at a time\n"
  local chunk = string.rep(line, 65536 // #line + 1)
  local rounds = 320 -- about 20 MiB
  local sink = assert(Stream.create(src .. "/big.txt"))
  for _ = 1, rounds do assert(sink:write(chunk)) end
  assert(sink:close())
  local total = #chunk * rounds
  collectgarbage()
  collectgarbage()
  local base = collectgarbage("count")
  -- Every read the run makes of a source file is preceded by a full
  -- collection and a sample of live memory: a run that read the file
  -- whole would hold all of it at once, and one that never opened it
  -- as a Stream would make no read at all.
  local real_open = Stream.open
  local reads, peak = 0, 0.0
  local patched = Stream as {string:any}
  patched.open = function(path: string): Stream.Reader | nil, string
    local opened, why = real_open(path)
    if opened == nil or path:sub(-7) ~= "big.txt" then return opened, why end
    local inner: Stream.Reader = opened
    local wrapped: Stream.Reader = {}
    wrapped.read = function(_self: Stream.Reader, max?: integer): string | nil, string
      collectgarbage()
      peak = math.max(peak, collectgarbage("count"))
      reads = reads + 1
      return inner:read(max)
    end
    wrapped.close = function(_self: Stream.Reader): boolean, string return inner:close() end
    return wrapped, ""
  end
  local ok, ran = pcall(in_dir, src, { "create", tmp .. "/out.zip", "big.txt" })
  patched.open = real_open
  assert(ok, ran)
  local made = ran as Ran
  assert(made.code == 0 and made.err == "", made.err)
  assert(reads >= rounds // 2, "the file was read " .. tostring(reads) .. " times")
  -- Reading the file whole would hold all of it, and its deflated copy.
  local grown = (peak - base) / 1024
  assert(grown < 4, ("memory grew %.1f MiB packing %d MiB"):format(grown, total >> 20))
  local r = assert(Zip.open(tmp .. "/out.zip"))
  local entries = r:entries()
  assert(#entries == 1 and entries[1].size == total)
  local body = assert(entries[1]:open())
  local seen = 0
  while true do
    local got, why = body:read(1 << 16)
    if got == nil then
      assert(why == "", why)
      break
    end
    seen = seen + #got
  end
  assert(seen == total)
  assert(r:close())
end

--- Runs `create` of `out` from `src` with every `Stream.open` of a
--- ".txt" file counted, and each read past the end given `extra` more
--- bytes when it is not "" (a file that grows as it is read). Returns
--- the run, the opens and the closes the archive made.
local function create_counting(src: string, out: string, extra: string): Ran, integer, integer
  local real_open = Stream.open
  local opens, closes = 0, 0
  local patched = Stream as {string:any}
  patched.open = function(path: string): Stream.Reader | nil, string
    local opened, why = real_open(path)
    if opened == nil or path:sub(-4) ~= ".txt" then return opened, why end
    opens = opens + 1
    local inner: Stream.Reader = opened
    local wrapped: Stream.Reader = {}
    local grown = false
    wrapped.read = function(_self: Stream.Reader, max?: integer): string | nil, string
      local got, trouble = inner:read(max)
      if got == nil and trouble == "" and extra ~= "" and not grown then
        grown = true
        return extra, ""
      end
      return got, trouble
    end
    wrapped.close = function(_self: Stream.Reader): boolean, string
      closes = closes + 1
      return inner:close()
    end
    return wrapped, ""
  end
  local ok, ran = pcall(in_dir, src, { "create", out, "tree" })
  patched.open = real_open
  assert(ok, ran)
  return ran as Ran, opens, closes
end

local function test_create_closes_every_file_it_opens(tmp: string)
  local src = make_tree(tmp)
  for _, name in ipairs({ "out.zip", "out.tar.gz" }) do
    local ran, opens, closes = create_counting(src, tmp .. "/" .. name, "")
    assert(ran.code == 0, ran.err)
    assert(opens > 0 and opens == closes, name .. ": " .. tostring(opens) .. " opened, " ..
      tostring(closes) .. " closed")
  end
end

local function test_create_of_a_file_that_grew_fails_and_leaves_no_archive(tmp: string)
  local src = make_tree(tmp)
  for _, name in ipairs({ "grew.zip", "grew.tar.gz" }) do
    local out = tmp .. "/" .. name
    local ran, opens, closes = create_counting(src, out, "grown")
    assert(ran.code == 2 and (ran.err:find("bytes, not", 1, true) or ran.err:find("bytes as it was read", 1, true)),
      name .. ": " .. ran.err)
    assert(opens > 0 and opens == closes, name)
    assert(not Fs.exists(out), name .. ": a failed create left an archive behind")
  end
end

local function test_create_a_gzip_tar_round_trips_with_a_symlink(tmp: string)
  local src = make_tree(tmp)
  assert(Fs.symlink("a.txt", src .. "/tree/link"))
  for _, out in ipairs({ "out.tar.gz", "OUT.TGZ" }) do
    local ran = in_dir(src, { "create", tmp .. "/" .. out, "./tree/", "loose.txt" })
    assert(ran.code == 0 and ran.err == "", ran.err)
    assert(ran.out:find("tree/link\n", 1, true), ran.out)
    local dest = tmp .. "/back-" .. out
    local back = run({ "extract", tmp .. "/" .. out, "-C", dest })
    assert(back.code == 0, back.err)
    assert(Fs.read(dest .. "/tree/z.txt") == "zed")
    assert(assert(Fs.readlink(dest .. "/tree/link")) == "a.txt")
    assert(Fs.read(dest .. "/loose.txt") == "loose")
  end
  assert(run({ "list", tmp .. "/out.tar.gz" }).out:find("tree/link -> a.txt\t", 1, true))
end

local function test_reproducible_packs_the_same_bytes_whatever_the_times(tmp: string)
  local src = make_tree(tmp)
  for _, out in ipairs({ "r.zip", "r.tar.gz" }) do
    assert(in_dir(src, { "create", "--reproducible", tmp .. "/1-" .. out, "tree" }).code == 0)
    assert(Fs.set_mtime(src .. "/tree/a.txt", 1234567890))
    assert(in_dir(src, { "create", "--reproducible", tmp .. "/2-" .. out, "tree" }).code == 0)
    assert(Fs.read(tmp .. "/1-" .. out) == Fs.read(tmp .. "/2-" .. out), out)
    assert(Fs.set_mtime(src .. "/tree/a.txt", 1700000000))
    assert(in_dir(src, { "create", tmp .. "/3-" .. out, "tree" }).code == 0)
    assert(Fs.read(tmp .. "/3-" .. out) ~= Fs.read(tmp .. "/1-" .. out), out)
  end
end

local function test_create_refuses_xz_bzip2_and_what_it_cannot_name(tmp: string)
  local src = make_tree(tmp)
  local xz = in_dir(src, { "create", tmp .. "/x.tar.xz", "loose.txt" })
  assert(xz.code == 2 and xz.out == "", xz.out)
  assert(xz.err:find("no xz encoder", 1, true), xz.err)
  assert(not Fs.exists(tmp .. "/x.tar.xz"))
  local bz = in_dir(src, { "create", tmp .. "/x.tar.bz2", "loose.txt" })
  assert(bz.code == 2 and bz.err:find("no bzip2 encoder", 1, true), bz.err)
  local plain = in_dir(src, { "create", tmp .. "/x.tar", "loose.txt" })
  assert(plain.code == 2 and plain.err:find(".tar.gz or .zip", 1, true), plain.err)
  local unknown = in_dir(src, { "create", tmp .. "/x.data", "loose.txt" })
  assert(unknown.code == 2 and unknown.err:find("end it in .zip or .tar.gz", 1, true), unknown.err)
end

local function test_create_refuses_paths_that_would_extract_outside(tmp: string)
  local src = make_tree(tmp)
  local up = in_dir(src, { "create", tmp .. "/u.zip", "../src/loose.txt" })
  assert(up.code == 2 and up.err:find("extract outside", 1, true), up.err)
  local absolute = in_dir(src, { "create", tmp .. "/a.zip", src .. "/loose.txt" })
  assert(absolute.code == 2 and absolute.err:find("extract outside", 1, true), absolute.err)
  assert(not Fs.exists(tmp .. "/u.zip") and not Fs.exists(tmp .. "/a.zip"))
  local missing = in_dir(src, { "create", tmp .. "/m.zip", "nope" })
  assert(missing.code == 1 and missing.err:find("nope", 1, true), missing.err)
  assert(Fs.symlink("loose.txt", src .. "/ln"))
  local link = in_dir(src, { "create", tmp .. "/l.zip", "ln" })
  assert(link.code == 2 and link.err:find("zip does not hold", 1, true), link.err)
  assert(not Fs.exists(tmp .. "/l.zip"))
end

local function test_create_leaves_an_existing_output_out_of_itself(tmp: string)
  local src = make_tree(tmp)
  assert(in_dir(src, { "create", "again.zip", ".", "loose.txt" }).code == 0)
  local second = in_dir(src, { "create", "again.zip", "." })
  assert(second.code == 0, second.err)
  assert(not second.out:find("again.zip", 1, true), second.out)
end

local function test_a_failed_standard_output_exits_2(tmp: string)
  local path = make_tar(tmp .. "/w.tar", SAMPLE)
  local ran = run({ "list", path }, nil, false)
  assert(ran.code == 2 and ran.err:find("standard output: no space left", 1, true), ran.err)
end

local function test_a_command_line_that_is_not_one_is_refused(tmp: string)
  local path = make_tar(tmp .. "/c.tar", SAMPLE)
  for _, words in ipairs({
    {}, { "bogus" }, { "list" }, { "list", path, "extra" }, { "extract" }, { "create" },
    { "create", tmp .. "/o.zip" }, { "list", "--no-such", path }, { "list", "-C", tmp, path },
    { "extract", "--json", path }, { "list", "--force", path }, { "extract", "--reproducible", path },
    { "list", "" }, { "extract", path, "" },
  } as {{string}}) do
    local ran = run(words)
    assert(ran.code == 2 and ran.out == "", table.concat(words, " ") .. " exited " .. ran.code)
    assert(ran.err:find("cosmic: archive: ", 1, true) == 1, ran.err)
    assert(ran.err:find("cosmic archive list", 1, true), ran.err)
  end
end

--- A ustar header, alone, for an entry of `flag` (`"1"` a hard link)
--- that `Tar.Writer` cannot write, followed by the end of the archive.
local function raw_entry(path: string, flag: string, linkname: string): string
  local function field(text: string, width: integer): string
    return text .. string.rep("\0", width - #text)
  end
  local head = field(path, 100) .. field("0000644", 8) .. field("0000000", 8) ..
    field("0000000", 8) .. field("00000000000", 12) .. field("00000000000", 12) ..
    "        " .. flag .. field(linkname, 100) .. "ustar\0" .. "00"
  head = head .. string.rep("\0", 512 - #head)
  local sum = 0
  for index = 1, #head do sum = sum + head:byte(index) end
  local check = string.format("%06o\0 ", sum)
  return head:sub(1, 148) .. check .. head:sub(157) .. string.rep("\0", 1024)
end

local function test_a_fifo_in_a_directory_is_refused_by_name(tmp: string)
  local src = make_tree(tmp)
  assert(sys.mkfifo(src .. "/tree/sub/pipe"))
  for _, out in ipairs({ "f.zip", "f.tar.gz" }) do
    local ran = in_dir(src, { "create", tmp .. "/" .. out, "tree" })
    assert(ran.code == 2 and ran.out == "", ran.out)
    assert(ran.err:find("tree/sub/pipe: neither a file, a directory nor a symlink", 1, true), ran.err)
    assert(not Fs.exists(tmp .. "/" .. out), "nothing is written")
  end
  local named = in_dir(src, { "create", tmp .. "/n.zip", "tree/sub/pipe" })
  assert(named.code == 2 and named.err:find("tree/sub/pipe", 1, true), named.err)
end

local function test_a_refusal_partway_leaves_the_entries_before_it(tmp: string)
  local dest = tmp .. "/dest"
  local link = make_tar(tmp .. "/a.tar", { file_member("first.txt", "1"),
    link_member("out", "../../elsewhere"), file_member("last.txt", "2") })
  local ran = run({ "extract", link, "-C", dest })
  assert(ran.code == 2, ran.err)
  assert(Fs.read(dest .. "/first.txt") == "1", "the entry before the refusal stays written")
  assert(not Fs.exists(dest .. "/out") and not Fs.exists(dest .. "/last.txt"))
  local dots = make_tar(tmp .. "/b.tar", { file_member("kept.txt", "1"),
    file_member("../gone.txt", "2") })
  assert(run({ "extract", dots, "-C", tmp .. "/dest2" }).code == 2)
  assert(Fs.read(tmp .. "/dest2/kept.txt") == "1")
  assert(not Fs.exists(tmp .. "/gone.txt"))
end

local function test_a_hard_link_is_refused(tmp: string)
  local path = tmp .. "/h.tar"
  assert(Fs.write(path, raw_entry("hard", "1", "target")))
  local ran = run({ "extract", path, "-C", tmp .. "/dest" })
  assert(ran.code == 2 and ran.err:find("hardlink", 1, true), ran.err)
  assert(not Fs.exists(tmp .. "/dest/hard"))
  assert(run({ "list", path }).out:find("hard -> target\t0\t0644\thardlink", 1, true))
end

local function test_force_never_writes_through_a_symlink_in_the_target(tmp: string)
  local outside = tmp .. "/outside.txt"
  assert(Fs.write(outside, "precious"))
  local dest = tmp .. "/dest"
  assert(Fs.mkdirs(dest))
  assert(Fs.symlink(outside, dest .. "/file"))
  assert(Fs.mkdirs(tmp .. "/outdir"))
  assert(Fs.symlink(tmp .. "/outdir", dest .. "/dir"))
  -- A file named for a link replaces the link, not what it leads to.
  local replace = run({ "extract", "--force", make_tar(tmp .. "/a.tar",
    { file_member("file", "new") }), "-C", dest })
  assert(replace.code == 0, replace.err)
  assert(Fs.read(outside) == "precious", "the file the link led to is untouched")
  assert(Fs.read(dest .. "/file") == "new")
  -- A path through a link that is already there is refused.
  local through = run({ "extract", "--force", make_tar(tmp .. "/b.tar",
    { file_member("dir/f.txt", "x") }), "-C", dest })
  assert(through.code == 2, through.err)
  assert(not Fs.exists(tmp .. "/outdir/f.txt"))
end

local function test_symlink_chains_and_a_directory_then_a_link_are_refused(tmp: string)
  -- a -> b, b -> ..: the second leaves the target.
  local chain = run({ "extract", make_tar(tmp .. "/a.tar",
    { link_member("a", "b"), link_member("b", "..") }), "-C", tmp .. "/one/dest" })
  assert(chain.code == 2, chain.err)
  assert(not Fs.exists(tmp .. "/one/dest/b"))
  -- b -> ., a -> b/..: a target through another link is refused.
  local hop = run({ "extract", make_tar(tmp .. "/b.tar",
    { link_member("b", "."), link_member("a", "b/..") }), "-C", tmp .. "/two/dest" })
  assert(hop.code == 2, hop.err)
  -- A directory, then a link of its name, then a file under it.
  local dir_link = run({ "extract", make_tar(tmp .. "/c.tar",
    { dir_member("d"), link_member("d", "."), file_member("d/f.txt", "x") }),
    "-C", tmp .. "/three/dest" })
  assert(dir_link.code == 2, dir_link.err)
  assert(not Fs.exists(tmp .. "/three/dest/f.txt"))
end
