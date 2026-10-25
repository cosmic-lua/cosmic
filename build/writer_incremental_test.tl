--- Tests of the write that starts from the projection already standing
--- ([`build.writer`]'s `usable_base`): whatever it carries over, its
--- bytes are those of a write of the whole tree, since a projection's
--- digest names verdicts that checkouts share and two builds of one tree
--- compare their files.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local importer = require("build.importer")
local work = require("build.work")
local writer = require("build.writer")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "core", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" },
  { path = "lang/stdlib.d.tl", letters = "r" } } }


--- One module of the tree: the variants of each part that an edit moves, so
--- that a step is one change to one record. `dep` is the module it requires,
--- `-` for none. A tree is the lines of its modules in the order of their
--- names, each `encode`d, which keeps every edit a new value.
local record Spec
  name: string
  body: integer
  comment: integer
  doc: integer
  errors: integer
  dep: string
  example: integer
  declared: integer
end

local function encode(spec: Spec): string
  return string.format("%s %d %d %d %d %s %d %d\n", spec.name, spec.body, spec.comment, spec.doc,
    spec.errors, spec.dep, spec.example, spec.declared)
end

local function integer_of(text: string?): integer
  return assert(math.tointeger(tonumber(assert(text))))
end

local function decode(line: string): Spec
  local name, body, comment, doc, errors, dep, example, declared =
    line:match("^(%S+) (%d+) (%d+) (%d+) (%d+) (%S+) (%d+) (%d+)$")
  return {
    name = assert(name), body = integer_of(body), comment = integer_of(comment), doc = integer_of(doc),
    errors = integer_of(errors), dep = assert(dep), example = integer_of(example),
    declared = integer_of(declared),
  }
end

--- `text` where `flag` holds, else nothing.
local function when(flag: boolean, text: string): string
  if flag then
    return text
  end
  return ""
end

--- `make(1)` .. `make(2)` .. up to `make(count)`.
local function repeated(count: integer, make: function(integer): string): string
  local out = ""
  for index = 1, count do
    out = out .. make(index)
  end
  return out
end

local function module_source(spec: Spec): string
  local requiring = spec.dep ~= "-"
  return when(requiring, 'local Dep = require("' .. spec.dep .. '")\n') ..
    repeated(spec.doc, function(line: integer): string
      return "--- Doc " .. spec.name .. " line " .. tostring(line) .. " of " .. tostring(spec.doc) .. ".\n"
    end) ..
    when(spec.doc > 0 and requiring, "--- See [`Dep.value`].\n") ..
    "local record M\nend\n" ..
    when(spec.comment > 0, "-- a plain comment " .. tostring(spec.comment) .. "\n") ..
    "--- Value " .. spec.name .. ".\nfunction M.value(): integer\n" ..
    when(requiring, "  local _ = Dep.value()\n") ..
    "  return " .. tostring(spec.body) .. "\nend\n" ..
    repeated(spec.errors, function(count: integer): string
      return "function M.fail" .. tostring(count) .. "(): nil, string\n  return nil, \"failed " ..
        spec.name .. " " .. tostring(count) .. "\"\nend\n"
    end) ..
    "return M\n"
end

local function example_source(spec: Spec): string
  return "local record Example\nend\n" ..
    repeated(spec.example, function(index: integer): string
      return "--- Shows " .. tostring(index) .. ".\nfunction Example.show" .. tostring(index) .. "()\nend\n"
    end) ..
    "return Example\n"
end

local function declaration_source(spec: Spec): string
  return "--- Declared " .. spec.name .. " " .. tostring(spec.declared) .. ".\nlocal record M\n" ..
    "  value: function(): integer\nend\nreturn M\n"
end

--- Writes the files of the tree `tree` under `root`, and removes those of
--- the modules named in `gone` (separated by spaces).
local function write_tree(root: string, tree: string, gone: string)
  assert(Fs.mkdirs(root))
  for name in gone:gmatch("%S+") do
    for _, suffix in ipairs({ ".tl", "_example.tl", ".d.tl" }) do
      local _ = Fs.remove(root .. "/" .. name .. suffix)
    end
  end
  for line in tree:gmatch("[^\n]+") do
    local spec = decode(line)
    assert(Fs.write(root .. "/" .. spec.name .. ".tl", module_source(spec)))
    local example = root .. "/" .. spec.name .. "_example.tl"
    if spec.example > 0 then
      assert(Fs.write(example, example_source(spec)))
    else
      local _ = Fs.remove(example)
    end
    local declaration = root .. "/" .. spec.name .. ".d.tl"
    if spec.declared > 0 then
      assert(Fs.write(declaration, declaration_source(spec)))
    else
      local _ = Fs.remove(declaration)
    end
  end
  assert(Fs.write(root .. "/main.tl", "return function(): integer\n  return 0\nend\n"))
end

local function plain(name: string, dep: string): Spec
  return { name = name, body = 1, comment = 0, doc = 1, errors = 1, dep = dep, example = 0, declared = 0 }
end

--- Each module requiring the one before it.
local initial <const>: string =
  encode(plain("a1", "-")) .. encode(plain("b2", "a1")) .. encode(plain("c3", "b2")) ..
  encode(plain("d4", "c3")) .. encode(plain("e5", "d4"))

--- `tree` with the module `name` as `change` makes it.
local function changed(tree: string, name: string, change: function(Spec): Spec): string
  local out = ""
  for line in tree:gmatch("[^\n]+") do
    local spec = decode(line)
    if spec.name == name then
      out = out .. encode(change(spec))
    else
      out = out .. line .. "\n"
    end
  end
  return out
end

--- `spec` with its `body` as given.
local function with_body(spec: Spec, body: integer): Spec
  return {
    name = spec.name, body = body, comment = spec.comment, doc = spec.doc, errors = spec.errors,
    dep = spec.dep, example = spec.example, declared = spec.declared,
  }
end

--- `spec` with the one part `part` names as `value`, and the rest as it was.
local function with_part(spec: Spec, part: string, value: integer): Spec
  local function choose(wanted: string, now: integer): integer
    if part == wanted then
      return value
    end
    return now
  end
  return {
    name = spec.name, body = choose("body", spec.body), comment = choose("comment", spec.comment),
    doc = choose("doc", spec.doc), errors = choose("errors", spec.errors), dep = spec.dep,
    example = choose("example", spec.example), declared = choose("declared", spec.declared),
  }
end

--- `tree` with `spec` placed among the modules in the order of the names.
local function added(tree: string, spec: Spec): string
  local out = ""
  local placed = false
  for line in tree:gmatch("[^\n]+") do
    if not placed and decode(line).name > spec.name then
      out = out .. encode(spec)
      placed = true
    end
    out = out .. line .. "\n"
  end
  if not placed then
    out = out .. encode(spec)
  end
  return out
end

--- `tree` without the module `name`, those that required it requiring
--- `instead` (`-` for none).
local function without(tree: string, name: string, instead: string): string
  local out = ""
  for line in tree:gmatch("[^\n]+") do
    local spec = decode(line)
    if spec.name ~= name then
      if spec.dep == name then
        out = out .. encode({
          name = spec.name, body = spec.body, comment = spec.comment, doc = spec.doc,
          errors = spec.errors, dep = instead, example = spec.example, declared = spec.declared,
        })
      else
        out = out .. line .. "\n"
      end
    end
  end
  return out
end

local function modules_in(tree: string): integer
  local count = 0
  for _ in tree:gmatch("[^\n]+") do
    count = count + 1
  end
  return count
end

--- The name of the `index`th module of `tree`, from 0.
local function name_at(tree: string, index: integer): string
  local at = 0
  for line in tree:gmatch("[^\n]+") do
    if at == index then
      return decode(line).name
    end
    at = at + 1
  end
  return decode(assert(tree:match("[^\n]+"))).name
end

local function spec_of(tree: string, name: string): Spec
  for line in tree:gmatch("[^\n]+") do
    local spec = decode(line)
    if spec.name == name then
      return spec
    end
  end
  return plain(name, "-")
end

local function advance(seed: integer): integer
  return (seed * 1103515245 + 12345) % 2147483648
end

--- A number below `limit` that `seed` gives.
local function below(seed: integer, limit: integer): integer
  return (seed // 65536) % limit
end

--- What a step did: the tree it left, what it was, the modules whose files
--- are no more (separated by spaces), and the seed to draw the next from.
local record Step
  tree: string
  label: string
  gone: string
  seed: integer
end

--- One edit to `tree`, drawn from `seed`.
local function edit(tree: string, seed: integer, serial: integer): Step
  local first = advance(seed)
  local second = advance(first)
  local third = advance(second)
  local pick = name_at(tree, below(first, modules_in(tree)))
  local op = below(second, 10)
  local function part(name: string, limit: integer): Step
    return {
      tree = changed(tree, pick, function(spec: Spec): Spec
        return with_part(spec, name, below(third, limit))
      end),
      label = name .. " of " .. pick, gone = "", seed = third,
    }
  end
  if op == 0 then
    return {
      tree = changed(tree, pick, function(spec: Spec): Spec
        return with_body(spec, spec.body + 1)
      end),
      label = "body of " .. pick, gone = "", seed = third,
    }
  elseif op == 1 then
    return {
      tree = changed(tree, pick, function(spec: Spec): Spec
        return with_part(spec, "comment", spec.comment + 1)
      end),
      label = "comment in " .. pick, gone = "", seed = third,
    }
  elseif op == 2 then
    return part("doc", 4)
  elseif op == 3 then
    return part("errors", 3)
  elseif op == 4 then
    return part("example", 3)
  elseif op == 5 then
    return part("declared", 3)
  elseif op == 6 or op == 7 then
    local name = "n" .. tostring(serial)
    return { tree = added(tree, plain(name, pick)), label = "added " .. name, gone = "", seed = third }
  elseif op == 8 and modules_in(tree) > 2 then
    return { tree = without(tree, pick, "-"), label = "removed " .. pick, gone = pick, seed = third }
  elseif op == 9 and modules_in(tree) > 2 then
    local name = "r" .. tostring(serial)
    local spec = spec_of(tree, pick)
    local renamed: Spec = {
      name = name, body = spec.body, comment = spec.comment, doc = spec.doc, errors = spec.errors,
      dep = spec.dep, example = spec.example, declared = spec.declared,
    }
    return {
      tree = added(without(tree, pick, name), renamed),
      label = "renamed " .. pick .. " to " .. name, gone = pick, seed = third,
    }
  end
  return { tree = tree, label = "nothing", gone = "", seed = third }
end

--- How many modules the write at `handle` took from the base: the rows of
--- `temp.reused`, which a write that found no usable base leaves absent.
local function reused(handle: work.Handle): integer
  local rows = Sqlite.text_rows(handle.db, "SELECT count(*) FROM temp.reused")
  if rows == nil then
    return 0
  end
  return integer_of(assert(rows[1]):text(1))
end

--- Stages and compiles the tree under the handle's root, writes it to `out`
--- and then as a whole to `whole` (a path nothing stands at), and returns
--- how many modules the first took from what stood at `out`.
local function write_both(handle: work.Handle, out: string, whole: string, tool: string, own?: boolean): integer
  assert(work.stage(handle, own == true))
  local result = assert(importer.compile(handle, tool))
  assert(handle.db:exec("DROP TABLE IF EXISTS temp.reused"))
  assert(writer.write_result(handle, out, result))
  local taken = reused(handle)
  assert(handle.db:exec("DROP TABLE IF EXISTS temp.reused"))
  local _ = Fs.remove(whole)
  assert(writer.write_result(handle, whole, result))
  assert(reused(handle) == 0, "a write with nothing standing took modules from a base")
  return taken
end

local function same_bytes(left: string, right: string, step: string)
  local a = assert(Fs.read(left))
  local b = assert(Fs.read(right))
  assert(a == b, step .. ": the projection written from the base differs from the whole write (" ..
      tostring(#a) .. " and " .. tostring(#b) .. " bytes)")
end

--- A projection written from the one standing is the projection a write of
--- the whole tree makes, whatever the edit: a body or a comment, a doc
--- comment that moves the ids of `docs` and the entries of `catalog` and
--- `examples` after it, a module added, removed or renamed, a declaration
--- stood in for one. Each of several sequences runs from the previous step's
--- file, so a difference would be carried forward; and each of them takes
--- modules from the base at least once, or this is no test of that.
local function test_a_write_from_a_base_is_a_write_of_the_whole(tmp: string)
  local taken = 0
  for sequence = 1, 3 do
    local root = tmp .. "/tree" .. tostring(sequence)
    local out = tmp .. "/out" .. tostring(sequence) .. ".db"
    local whole = tmp .. "/whole" .. tostring(sequence) .. ".db"
    local tree = initial
    local seed = sequence * 7919
    write_tree(root, tree, "")
    local handle = assert(work.open(root))
    write_both(handle, out, whole, "writer-test")
    same_bytes(out, whole, "sequence " .. tostring(sequence) .. " start")
    for step = 1, 14 do
      local made = edit(tree, seed, step)
      tree, seed = made.tree, made.seed
      write_tree(root, tree, made.gone)
      local label = "sequence " .. tostring(sequence) .. " step " .. tostring(step) .. " (" .. made.label .. ")"
      taken = taken + write_both(handle, out, whole, "writer-test")
      same_bytes(out, whole, label)
    end
    assert(work.close(handle))
  end
  assert(taken > 0, "no write took a module from the base")
end

--- An edit to one module's body leaves to the base each module whose key it
--- does not move: those that do not require the module, directly or not.
local function test_an_edit_to_one_module_takes_the_unrelated_from_the_base(tmp: string)
  write_tree(tmp .. "/t", initial, "")
  local handle = assert(work.open(tmp .. "/t"))
  write_both(handle, tmp .. "/out.db", tmp .. "/whole.db", "writer-test")
  write_tree(tmp .. "/t", changed(initial, "c3", function(spec: Spec): Spec
    return with_body(spec, 2)
  end), "")
  local taken = write_both(handle, tmp .. "/out.db", tmp .. "/whole.db", "writer-test")
  same_bytes(tmp .. "/out.db", tmp .. "/whole.db", "body edit")
  -- a1, b2 and main stand; c3 is edited, and d4 and e5 require it.
  assert(taken == 3, "three of six modules stand, took " .. tostring(taken))
  assert(work.close(handle))
end

--- Where a base cannot stand in for the rows -- another compiler wrote
--- it, or it holds another schema, another declaration, another core --
--- the write is whole, and equals the whole write.
local function test_a_base_that_cannot_stand_in_is_not_used(tmp: string)
  local tampers: {string:string} = {
    compiler = "UPDATE meta SET value = 'other' WHERE key = 'compiled_by'",
    writer = "UPDATE meta SET value = 'other' WHERE key = 'written_by'",
    core = "INSERT OR REPLACE INTO meta (key, value) VALUES ('image_hash', x'00')",
    basis = "UPDATE meta SET value = x'00' WHERE key = 'runtime_basis'",
    signature = "UPDATE meta SET value = 'other' WHERE key = 'projected'",
    schema = "CREATE TABLE extra (x)",
    declaration = "INSERT INTO decls (path, source) VALUES ('stray', x'00')",
  }
  for name, statement in pairs(tampers) do
    local root = tmp .. "/" .. name
    write_tree(root, initial, "")
    local handle = assert(work.open(root))
    write_both(handle, root .. ".db", root .. ".whole.db", "writer-test")
    local db = assert(Sqlite.open(root .. ".db", { writable = true }))
    assert(db:exec(statement))
    assert(db:close())
    write_tree(root, changed(initial, "b2", function(spec: Spec): Spec return with_body(spec, 5) end), "")
    local taken = write_both(handle, root .. ".db", root .. ".whole.db", "writer-test")
    assert(taken == 0, name .. ": a base that cannot stand in was used")
    same_bytes(root .. ".db", root .. ".whole.db", name)
    assert(work.close(handle))
  end
end

--- A compiler of another identity writes the whole projection too.
local function test_another_compiler_writes_the_whole_projection(tmp: string)
  write_tree(tmp .. "/t", initial, "")
  local handle = assert(work.open(tmp .. "/t"))
  write_both(handle, tmp .. "/out.db", tmp .. "/whole.db", "writer-test")
  write_tree(tmp .. "/t", changed(initial, "a1", function(spec: Spec): Spec
    return with_body(spec, 9)
  end), "")
  local taken = write_both(handle, tmp .. "/out.db", tmp .. "/whole.db", "another-tool")
  assert(taken == 0, "a projection another compiler wrote was built on")
  same_bytes(tmp .. "/out.db", tmp .. "/whole.db", "another compiler")
  assert(work.close(handle))
end

--- A PEM block holding `bytes`, which need be no certificate.
local function block(bytes: string): string
  return "-----BEGIN CERTIFICATE-----\n" .. Codec.base64(bytes) .. "\n-----END CERTIFICATE-----\n"
end

--- A changeset revoking one certificate named by `issuer` and `serial`.
local function changeset(issuer: string, serial: string): string
  return '{"metadata":{},"timestamp":1792622041776,"changes":[{"issuerName":"' ..
    Codec.base64(issuer) .. '","serialNumber":"' .. Codec.base64(serial) .. '"}]}'
end

--- Marks the rows of the CA tables of the projection at `path`, so that a
--- write is seen to have taken them from it or to have made them again.
local function mark(path: string)
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("UPDATE ca_roots SET label = 'marked'"))
  assert(db:exec("UPDATE ca_revoked SET kind = 'marked'"))
  assert(db:close())
end

--- How many rows of the CA tables of the projection at `path` carry the mark.
local function marked(path: string): integer
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT (SELECT count(*) FROM ca_roots WHERE label = 'marked') + " ..
      "(SELECT count(*) FROM ca_revoked WHERE kind = 'marked')"))
  assert(db:close())
  return integer_of(assert(rows[1]):text(1))
end

--- The tables of CA roots and revoked certificates of cosmic's own tree are
--- parsed from two files; a write from a base parses them again only where
--- one moved, and is the whole write every way: an edit to neither, to the
--- bundle, to the snapshot, the snapshot gone. A mark on the base's rows
--- stays where they were carried and goes where they were made again.
local function test_the_ca_tables_stand_or_move_with_their_files(tmp: string)
  local root = tmp .. "/own"
  local out, whole = tmp .. "/own.db", tmp .. "/own.whole.db"
  local function put(tree: string)
    write_tree(root, tree, "")
    assert(Fs.mkdirs(root .. "/core"))
    assert(Fs.mkdirs(root .. "/build"))
    assert(Fs.mkdirs(root .. "/vendor/cacert"))
    assert(Fs.mkdirs(root .. "/vendor/onecrl"))
    assert(Fs.write(root .. "/build/importer.tl", "local record importer\nend\nreturn importer\n"))
    -- A tree that is cosmic's own is checked against the declarations of the standard library it holds.
    assert(Fs.mkdirs(root .. "/lang"))
    assert(Fs.write(root .. "/lang/prelude.d.tl", (assert(Fs.read("lang/prelude.d.tl")))))
    assert(Fs.write(root .. "/lang/stdlib.d.tl", (assert(Fs.read("lang/stdlib.d.tl")))))
    assert(Fs.write(root .. "/build/ceilings.txt", "[checked]\n"))
  end
  put(initial)
  assert(Fs.write(root .. "/vendor/cacert/certdata.txt", block("one") .. block("two")))
  assert(Fs.write(root .. "/vendor/onecrl/onecrl.json", changeset("issuer", "7")))
  local handle = assert(work.open(root))
  write_both(handle, out, whole, "writer-test", true)
  same_bytes(out, whole, "start")
  assert(marked(out) == 0)

  put(changed(initial, "b2", function(spec: Spec): Spec return with_body(spec, 4) end))
  assert(write_both(handle, out, whole, "writer-test", true) > 0, "no module came from the base")
  same_bytes(out, whole, "a module's body")

  -- Nothing but a module moved: the marked rows are the base's, carried.
  mark(out)
  put(changed(initial, "b2", function(spec: Spec): Spec return with_body(spec, 5) end))
  assert(write_both(handle, out, whole, "writer-test", true) > 0, "no module came from the base")
  assert(marked(out) == 3, "the CA tables were made again, not carried: " .. tostring(marked(out)))

  -- A change to either file comes with a pin's in the tree, which moves
  -- the signature as an edit to a module does.
  put(changed(initial, "a1", function(spec: Spec): Spec return with_body(spec, 5) end))
  assert(Fs.write(root .. "/vendor/cacert/certdata.txt", block("one") .. block("three")))
  assert(write_both(handle, out, whole, "writer-test", true) > 0, "no module came from the base")
  assert(marked(out) == 0, "a moved bundle was not parsed")
  same_bytes(out, whole, "the bundle")

  mark(out)
  put(changed(initial, "a1", function(spec: Spec): Spec return with_body(spec, 6) end))
  assert(Fs.write(root .. "/vendor/onecrl/onecrl.json", changeset("issuer", "8")))
  assert(write_both(handle, out, whole, "writer-test", true) > 0, "no module came from the base")
  assert(marked(out) == 0, "a moved snapshot was not parsed")
  same_bytes(out, whole, "the snapshot")

  put(changed(initial, "a1", function(spec: Spec): Spec return with_body(spec, 7) end))
  assert(Fs.remove(root .. "/vendor/onecrl/onecrl.json"))
  assert(write_both(handle, out, whole, "writer-test", true) > 0, "no module came from the base")
  same_bytes(out, whole, "the snapshot gone")
  assert(work.close(handle))
end

--- Overwrites the page `page` (1-based, of 4096 bytes) of the file at `path`.
local function ruin(path: string, page: integer)
  local bytes = assert(Fs.read(path))
  local start = (page - 1) * 4096
  assert(Fs.write(path, bytes:sub(1, start) .. string.rep("\255", 4096) .. bytes:sub(start + 4097)))
end

--- Whether the file at `path` still answers for its `meta`, its schema and
--- the columns that decide which modules stand (what [`build.writer`]'s
--- `usable_base` and `make_reused` ask) though a row it carries cannot be read.
local function readable_but_for_rows(path: string): boolean
  local db = Sqlite.open(path)
  if db == nil then
    return false
  end
  local asked = Sqlite.text_rows(db, "SELECT count(*) FROM meta") ~= nil and
    Sqlite.text_rows(db, "SELECT count(*) FROM sqlite_master") ~= nil and
    Sqlite.text_rows(db, "SELECT path, file, kind, source_hash, key FROM modules") ~= nil and
    Sqlite.text_rows(db, "SELECT path FROM decls") ~= nil
  local carried = Sqlite.text_rows(db, "SELECT * FROM modules") ~= nil and
    Sqlite.text_rows(db, "SELECT * FROM docs") ~= nil and
    Sqlite.text_rows(db, "SELECT * FROM uses") ~= nil
  assert(db:close())
  return asked and not carried
end

--- A projection standing whose pages are damaged where the write reads
--- them, but whose schema and `meta` still read, is no base: the write is
--- whole and replaces it, as it does a file that is no database. The write
--- that finds it so fails once, and removes it: the next is whole.
local function test_a_base_damaged_past_its_schema_is_written_over(tmp: string)
  local root = tmp .. "/damaged"
  local out, whole = root .. ".db", root .. ".whole.db"
  write_tree(root, initial, "")
  local handle = assert(work.open(root))
  write_both(handle, out, whole, "writer-test")
  local pristine = assert(Fs.read(out))
  local probe = root .. ".probe.db"
  local page = 0
  for candidate = 2, #pristine // 4096 do
    assert(Fs.write(probe, pristine))
    ruin(probe, candidate)
    if readable_but_for_rows(probe) then
      page = candidate
      break
    end
  end
  assert(page > 0, "no page of the projection leaves it readable but for its rows")
  ruin(out, page)
  write_tree(root, changed(initial, "b2", function(spec: Spec): Spec return with_body(spec, 5) end), "")
  assert(work.stage(handle, false))
  local result = assert(importer.compile(handle, "writer-test"))
  local written, _ = writer.write_result(handle, out, result)
  assert(not written, "a write read a damaged base to its end")
  assert(Fs.exists(out) ~= true, "a damaged base was left to fail the next write")
  write_both(handle, out, whole, "writer-test")
  same_bytes(out, whole, "a damaged base")
  assert(work.close(handle))
end

--- The record-field uses of a module that calls a method of a record
--- another module declares: the module's own text does not move when the
--- record is renamed in the other, so its rows are the base's only where its
--- key stands, and are those of the whole write.
local function test_a_use_of_another_modules_record_follows_that_module(tmp: string)
  local root = tmp .. "/typed"
  local out, whole = tmp .. "/typed.db", tmp .. "/typed.whole.db"
  assert(Fs.mkdirs(root))
  local function put(record_name: string, extra: string)
    assert(Fs.write(root .. "/main.tl", "return function(): integer\n  return 0\nend\n"))
    assert(Fs.write(root .. "/b.tl",
      "local record M\n  record " .. record_name .. "\n    go: function(" .. record_name .. "): integer\n  end\nend\n" ..
        "--- Makes one" .. extra .. ".\nfunction M.make(): M." .. record_name ..
        "\n  return { go = function(_: M." .. record_name .. "): integer return 1 end }\nend\nreturn M\n"))
    assert(Fs.write(root .. "/a.tl",
      'local B = require("b")\nlocal record M\nend\n--- Runs, as [`B.make`] does.\n' ..
        "function M.run(): integer\n  local x: B." .. record_name .. " = B.make()\n  return x:go()\nend\nreturn M\n"))
    assert(Fs.write(root .. "/c.tl", 'local record M\nend\n--- Alone.\nfunction M.one(): integer\n  return 1\nend\nreturn M\n'))
  end
  local function uses_of_a(path: string): string
    local db = assert(Sqlite.open(path))
    local rows = assert(Sqlite.text_rows(db,
      "SELECT coalesce(group_concat(module || ' ' || symbol, ';'), '') FROM uses WHERE from_module = 'a'"))
    assert(db:close())
    return assert(rows[1]):text(1)
  end
  put("R1", "")
  local handle = assert(work.open(root))
  write_both(handle, out, whole, "writer-test")
  same_bytes(out, whole, "start")
  assert(uses_of_a(out) == "b R1.go;b make", uses_of_a(out))
  local record Change
    name: string
    extra: string
    uses: string
  end
  local steps: {Change} = {
    { name = "R2", extra = "", uses = "b R2.go;b make" },
    { name = "R2", extra = " again", uses = "b R2.go;b make" },
    { name = "R3", extra = " again", uses = "b R3.go;b make" },
  }
  for step, change in ipairs(steps) do
    put(change.name, change.extra)
    local taken = write_both(handle, out, whole, "writer-test")
    same_bytes(out, whole, "record step " .. tostring(step))
    assert(uses_of_a(out) == change.uses, "step " .. tostring(step) .. ": " .. uses_of_a(out))
    assert(taken >= 2, "main and c did not stand: " .. tostring(taken))
  end
  assert(work.close(handle))
end
