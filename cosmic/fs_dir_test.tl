--- [`Fs.dir`]: a directory reached with no link on its path, and acted on one name at a time, never through a link.
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

--- `tmp` by its real name, so no part of it is a link.
local function real(tmp: string): string
  return (assert(sys.realpath(tmp)))
end

--- A held directory reads, writes, makes and describes the names in it.
local function test_a_dir_acts_on_the_names_in_it(tmp: string)
  local root = real(tmp)
  local d <close> = assert(Fs.dir(root))
  assert(d.path == root)
  assert(d:write("note.txt", "kept"))
  assert(assert(d:read("note.txt")) == "kept")
  assert(assert(Fs.read(root .. "/note.txt")) == "kept")
  assert(d:write("note.txt", "again", 0x180))
  assert(assert(d:read("note.txt")) == "again")
  local st = assert(assert(d:status("note.txt")).stat)
  assert(st.kind == "file" and st.mode & 0x1ff == 0x180, tostring(st.mode))
  local gone = assert(d:status("absent"))
  assert(not gone.exists)
  assert(d:mkdir("inner"))
  local inner <close> = assert(d:dir("inner"))
  assert(inner.path == root .. "/inner")
  assert(inner:write("a", "alpha"))
  assert(assert(Fs.read(root .. "/inner/a")) == "alpha")
  -- No temporary file is left beside what was written.
  local names = assert(Fs.list(root))
  for _, name in ipairs(names) do assert(not name:find(".writing.", 1, true), name) end
end

--- A link on the path, its last part included, or at a name is met, never followed.
local function test_a_dir_never_follows_a_link(tmp: string)
  local root = real(tmp)
  assert(Fs.mkdirs(root .. "/inside"))
  assert(Fs.mkdirs(root .. "/outside"))
  assert(Fs.write(root .. "/outside/secret", "no"))
  assert(Fs.symlink(root .. "/outside", root .. "/inside/away"))
  assert(Fs.symlink(root .. "/outside/secret", root .. "/inside/file"))
  assert(Fs.symlink(root .. "/inside", root .. "/hop"))
  -- On the path, a part or the last one.
  local through, through_why = Fs.dir(root .. "/hop/away")
  assert(through == nil and through_why.errno == sys.ELOOP, tostring(through_why))
  local last, last_why = Fs.dir(root .. "/inside/away")
  assert(last == nil and last_why.errno == sys.ELOOP, tostring(last_why))
  -- At a name.
  local d <close> = assert(Fs.dir(root .. "/inside"))
  local read, read_why = d:read("file")
  assert(read == nil and read_why.errno == sys.ELOOP, tostring(read_why))
  local wrote, write_why = d:write("file", "over")
  -- The rename replaces the link itself, and the file it named is as it was.
  assert(wrote, tostring(write_why))
  assert(assert(Fs.read(root .. "/outside/secret")) == "no")
  assert(assert(assert(d:status("file")).stat).kind == "file")
  assert(assert(assert(d:status("away")).stat).kind == "link")
  local into, into_why = d:dir("away")
  assert(into == nil and into_why.errno == sys.ELOOP, tostring(into_why))
  local made, made_why = d:mkdir("away")
  assert(not made and made_why.errno == sys.EEXIST, tostring(made_why))
end

--- A name is one entry: "/", "." and ".." are refused.
local function test_a_dir_takes_one_name(tmp: string)
  local root = real(tmp)
  assert(Fs.mkdirs(root .. "/a/b"))
  local d <close> = assert(Fs.dir(root .. "/a"))
  for _, name in ipairs({ "", ".", "..", "b/c", "../a" }) do
    local read, why = d:read(name)
    assert(read == nil and why.errno == sys.EINVAL, name .. ": " .. tostring(why))
    local into, into_why = d:dir(name)
    assert(into == nil and into_why.errno == sys.EINVAL, name .. ": " .. tostring(into_why))
  end
  d:close()
  local closed, closed_why = d:read("b")
  assert(closed == nil and tostring(closed_why):find("closed", 1, true) ~= nil, tostring(closed_why))
end

--- Only a file is read: a directory, or a pipe, which would wait for a writer, is refused at once.
local function test_a_dir_reads_files_alone(tmp: string)
  local root = real(tmp)
  assert(Fs.mkdirs(root .. "/sub"))
  local d <close> = assert(Fs.dir(root))
  local read, why = d:read("sub")
  assert(read == nil and tostring(why):find("no file (dir)", 1, true) ~= nil, tostring(why))
  local made, _ = sys.mkfifo(root .. "/pipe", 0x1a4)
  if made then
    local piped, piped_why = d:read("pipe")
    assert(piped == nil and tostring(piped_why):find("no file", 1, true) ~= nil, tostring(piped_why))
  end
end

--- A name as long as a name may be is written: the temporary file's name does not grow with it.
local function test_a_dir_writes_the_longest_name(tmp: string)
  local root = real(tmp)
  local d <close> = assert(Fs.dir(root))
  local long = string.rep("n", 255)
  assert(d:write(long, "x"))
  assert(assert(d:read(long)) == "x")
end
