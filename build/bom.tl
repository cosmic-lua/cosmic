--- The bill of materials: every third-party component a cosmic binary
--- carries, with its version, where it came from, its license and the
--- notices that license asks a copy to travel with.
---
--- The facts live beside the pin they describe. A vendored tree's
--- `vendor/<name>/PIN` adds three keys to the ones `bin/vendor` reads:
---
---     kind data                        "library" when absent
---     license MIT AND APSL-2.0         an SPDX expression, the rest of the line
---     notice LICENSE.md                a file under the tree, the whole of it
---     notice src/lua.h:524-543         or those lines of it, 1-based
---
--- `notice` repeats, and every key but `notice` is read once, the first
--- line naming it winning, as `bin/vendor` reads its own. A PIN is part
--- of what the core is built from (`work.record_fingerprint`'s image
--- hash), so correcting one of these lines reboots the core as a
--- version bump does. What cosmic's build links in without vendoring it
--- -- zig's own runtime, and the musl libc the Linux cores are static
--- against -- has a record of the same grammar at `build/bom/<name>.pin`,
--- its notices beside it. A tree's patches under `patch/<name>/` are
--- listed with it, so a reader knows the code is not upstream's as
--- published.
---
--- The tool's database carries two tables built from these (see
--- `build.schema`): `components`, a row each, and `notices`, each
--- notice's text under the component that names it. `bom.fill` writes
--- them when the tool is built (`build.writer`'s `carried`), and refuses
--- a pin that names no license, so a newly vendored tree cannot ship
--- without one. `cosmic bom` prints them.
---
--- TODO: check each `license` as an SPDX expression of known ids rather
--- than taking the line as written, once the tree vendors SPDX's license
--- list to check against; `build/bom_test.tl` only holds it to the
--- `SPDX-License-Identifier` tags its tree's own files carry.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Time = require("cosmic.time")
local bind = require("build.bind")
local clock = require("build.clock")
local log = require("build.verdict").log

local text = bind.text

local record bom
  --- One `notice` line: a file under the component's directory, and
  --- the lines of it to keep; `first` is nil for the whole file.
  record Notice
    file: string
    first: integer | nil
    last: integer | nil
  end

  --- One record, as `bom.parse` reads it.
  record Component
    name: string
    kind: string
    version: string
    url: string
    --- The upstream archive's, as fetched; "" when the record names
    --- none (a component cosmic does not fetch itself).
    sha256: string
    license: string
    notices: {bom.Notice}
  end

  --- One component as the database holds it.
  record Row
    name: string
    kind: string
    version: string
    license: string
    url: string
    sha256: string
    --- `patch/<name>/<file> <sha256>`, one per line, in name order; ""
    --- for a component shipped as published.
    patches: string
  end
end

--- The kinds a component may be: CycloneDX's own words for them.
local kinds: {string:boolean} = { library = true, data = true }

--- A `notice` line's value: `path` or `path:first-last`.
local function notice_of(value: string): bom.Notice | nil, string
  local file, first, last = value:match("^(.-):(%d+)%-(%d+)$")
  if file == nil then
    if value:find(":", 1, true) ~= nil then
      return nil, "notice " .. value .. ": a range is written file:first-last"
    end
    return { file = value }
  end
  local from, to = math.tointeger(tonumber(first)), math.tointeger(tonumber(last))
  if from == nil or to == nil or from < 1 or to < from then
    return nil, "notice " .. value .. ": the range is empty"
  end
  return { file = file, first = from, last = to }
end

--- A record's text as a component named `name`: `version`, `url` and
--- `license` must be present; `sha256` and `kind` may be absent. Keys
--- this grammar does not know -- `strip`, `keep` and the rest
--- `bin/vendor` reads -- are skipped.
function bom.parse(name: string, source: string): bom.Component | nil, string
  local component: bom.Component = { name = name, kind = "library", version = "",
    url = "", sha256 = "", license = "", notices = {} }
  local seen: {string:boolean} = {}
  for line in String.lines(source) do
    local key, value = line:match("^([%w_]+)%s+(.-)%s*$")
    if key ~= nil and key ~= "notice" then
      if seen[key] then
        key = nil
      else
        seen[key] = true
      end
    end
    if key == "notice" then
      local notice, trouble = notice_of(value)
      if notice == nil then
        return nil, name .. ": " .. trouble
      end
      component.notices[#component.notices + 1] = notice
    elseif key == "license" then
      component.license = value
    elseif key == "version" or key == "url" or key == "sha256" then
      -- The first word, as `bin/vendor` reads these.
      local word = value:match("^%S+")
      if key == "version" then
        component.version = word
      elseif key == "url" then
        component.url = word
      else
        component.sha256 = word:lower()
      end
    elseif key == "kind" then
      if not kinds[value] then
        return nil, name .. ": kind " .. value .. " is neither library nor data"
      end
      component.kind = value
    end
  end
  local missing = component.version == "" and "version" or
    component.url == "" and "url" or component.license == "" and "license" or nil
  if missing ~= nil then
    return nil, name .. ": its record names no " .. missing
  end
  return component
end

--- A notice's text, read from under `directory`.
local function notice_text(directory: string, notice: bom.Notice): string | nil, string
  local path = directory .. "/" .. notice.file
  local data, trouble = Fs.read(path)
  if data == nil then
    return nil, trouble
  end
  data = data:gsub("\r\n", "\n")
  if notice.first == nil then
    if data:sub(-1) ~= "\n" then
      return data .. "\n"
    end
    return data
  end
  local kept: {string} = {}
  local number = 0
  local ended = data:sub(-1) == "\n" and data or data .. "\n"
  for line in ended:gmatch("([^\n]*)\n") do
    number = number + 1
    if number >= notice.first and number <= notice.last then
      kept[#kept + 1] = line
    end
  end
  if number < notice.last then
    return nil, path .. ": has " .. number .. " lines, not " .. notice.last
  end
  return table.concat(kept, "\n") .. "\n"
end

--- The files under `patch/<name>/`, each with its sha256, one per line.
local function patches_of(root: string, name: string): string | nil, string
  local directory = root .. "/patch/" .. name
  local exists, trouble = Fs.exists(directory)
  if exists == nil then
    return nil, trouble
  end
  if not exists then
    return ""
  end
  local names, list_trouble = Fs.list(directory)
  if names == nil then
    return nil, list_trouble
  end
  table.sort(names)
  local lines: {string} = {}
  for _, file in ipairs(names) do
    -- Only what `core/patch.c` applies: a patch record is a `.txt`.
    if String.ends_with(file, ".txt") and #file > 4 then
      local data, read_trouble = Fs.read(directory .. "/" .. file)
      if data == nil then
        return nil, read_trouble
      end
      lines[#lines + 1] = "patch/" .. name .. "/" .. file .. " " .. Hash.hex_sha256(data)
    end
  end
  return table.concat(lines, "\n")
end

--- The entries of `directory`, or none when there is no such directory:
--- a tree shaped like cosmic's own need not vendor anything.
local function entries(directory: string): {string} | nil, string
  local exists, trouble = Fs.exists(directory)
  if exists == nil then
    return nil, trouble
  end
  if not exists then
    return {}
  end
  return Fs.list(directory)
end

--- Where the records sit, as `{name, record path, notice directory}`,
--- sorted by name: every `vendor/*/PIN`, then every `build/bom/*.pin`.
local function records(root: string): {{string}} | nil, string
  local found: {{string}} = {}
  local vendored, trouble = entries(root .. "/vendor")
  if vendored == nil then
    return nil, trouble
  end
  for _, name in ipairs(vendored) do
    local directory = root .. "/vendor/" .. name
    local pinned, pin_trouble = Fs.exists(directory .. "/PIN")
    if pinned == nil then
      return nil, pin_trouble
    end
    if pinned then
      found[#found + 1] = { name, directory .. "/PIN", directory }
    end
  end
  local linked, linked_trouble = entries(root .. "/build/bom")
  if linked == nil then
    return nil, linked_trouble
  end
  for _, file in ipairs(linked) do
    local name = file:match("^(.+)%.pin$")
    if name ~= nil then
      found[#found + 1] = { name, root .. "/build/bom/" .. file, root .. "/build/bom" }
    end
  end
  table.sort(found, function(a: {string}, b: {string}): boolean
    return a[1] < b[1]
  end)
  for index = 2, #found do
    if found[index][1] == found[index - 1][1] then
      return nil, "two records name " .. found[index][1]
    end
  end
  return found
end

--- Writes the tree at `root`'s components and their notices into the
--- `components` and `notices` tables of the database `db` holds as
--- `qualifier` (`"main."`, say), which must be empty. Fails, writing
--- nothing it has not already, on a record that does not parse or a
--- notice that cannot be read.
function bom.fill(db: Sqlite.Handle, root: string, qualifier: string): boolean, string
  local found, trouble = records(root)
  if found == nil then
    return false, trouble
  end
  for _, entry in ipairs(found) do
    local name, path, directory = entry[1], entry[2], entry[3]
    local source, read_trouble = Fs.read(path)
    if source == nil then
      return false, read_trouble
    end
    local component, parse_trouble = bom.parse(name, source)
    if component == nil then
      return false, path .. ": " .. parse_trouble
    end
    local patches, patch_trouble = patches_of(root, name)
    if patches == nil then
      return false, patch_trouble
    end
    local inserted, insert_trouble = Sqlite.run(db,
      "INSERT INTO " .. qualifier .. "components (name, kind, version, license, url, " ..
      "sha256, patches) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      { text(name), text(component.kind), text(component.version),
        text(component.license), text(component.url), text(component.sha256),
        text(patches) })
    if not inserted then
      return false, insert_trouble
    end
    for ordinal, notice in ipairs(component.notices) do
      local body, notice_trouble = notice_text(directory, notice)
      if body == nil then
        return false, path .. ": " .. notice_trouble
      end
      local put, put_trouble = Sqlite.run(db,
        "INSERT INTO " .. qualifier .. "notices (component, ordinal, file, text) " ..
        "VALUES (?1, ?2, ?3, ?4)",
        { text(name), bind.integer(ordinal), text(notice.file), text(body) })
      if not put then
        return false, put_trouble
      end
    end
  end
  return true, ""
end

--- Every component `db` holds, by name.
function bom.rows(db: Sqlite.Handle): {bom.Row} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT name, kind, version, license, url, sha256, patches " ..
    "FROM components ORDER BY name")
  if rows == nil then
    return nil, trouble
  end
  local out: {bom.Row} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { name = row[1], kind = row[2], version = row[3],
      license = row[4], url = row[5], sha256 = row[6], patches = row[7] }
  end
  return out
end

--- One line per component: name, version, license, and whether cosmic
--- patches it.
local function lines_of(rows: {bom.Row}): {string}
  local lines: {string} = {}
  for _, row in ipairs(rows) do
    local line = row.name .. " " .. row.version .. "  " .. row.license
    if row.patches ~= "" then
      local _, breaks = row.patches:gsub("\n", "")
      local count = breaks + 1
      line = line .. "  (" .. count .. " patch" .. (count == 1 and "" or "es") .. ")"
    end
    lines[#lines + 1] = line
  end
  return lines
end

--- Every notice `db` holds, each under a heading naming its component
--- and file, in component order. A component that ships no notice --
--- public domain, or a license such as MPL-2.0 that asks instead that a
--- recipient be told where the source is -- gets its heading and that
--- source.
function bom.notices(db: Sqlite.Handle): string | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT c.name, c.version, c.license, c.url, n.file IS NULL, " ..
    "coalesce(n.file, ''), coalesce(n.text, '') FROM components c " ..
    "LEFT JOIN notices n ON n.component = c.name ORDER BY c.name, n.ordinal")
  if rows == nil then
    return nil, trouble
  end
  local parts: {string} = {}
  for _, row in ipairs(rows) do
    local head = "== " .. row[1] .. " " .. row[2] .. " (" .. row[3] .. ")"
    if row[5] == "1" then
      parts[#parts + 1] = head .. "\n\nno notice; its source: " .. row[4] .. "\n"
    else
      parts[#parts + 1] = head .. ": " .. row[6] .. "\n\n" .. row[7]
    end
  end
  return table.concat(parts, "\n")
end

--- `text` with every byte a URL query value may not hold as itself
--- written as `%XX`.
local function escaped(value: string): string
  return (value:gsub("[^%w%-%._~]", function(c: string): string
    return string.format("%%%02X", c:byte())
  end))
end

--- The rows as a CycloneDX 1.6 document, `subject` naming what they
--- are the materials of. A component's archive hash goes with the
--- distribution reference it came from: it is upstream's as published,
--- which a patched component's code no longer is.
function bom.cyclonedx(rows: {bom.Row}, subject: string, version: string): string | nil, string
  local components: {any} = {}
  for _, row in ipairs(rows) do
    local reference: {string:any} = { type = "distribution", url = row.url }
    if row.sha256 ~= "" then
      reference.hashes = { { alg = "SHA-256", content = row.sha256 } }
    end
    local component: {string:any} = {
      type = row.kind,
      ["bom-ref"] = row.name,
      name = row.name,
      version = row.version,
      purl = "pkg:generic/" .. escaped(row.name) .. "@" .. escaped(row.version) ..
        "?download_url=" .. escaped(row.url),
      licenses = { { expression = row.license } },
      externalReferences = { reference },
    }
    if row.patches ~= "" then
      component.pedigree = { notes = "patched by cosmic:\n" .. row.patches }
    end
    components[#components + 1] = component
  end
  return Json.encode({
    bomFormat = "CycloneDX",
    specVersion = "1.6",
    version = 1,
    metadata = { component = { type = "application", ["bom-ref"] = subject,
      name = subject, version = version } },
    components = Json.array(components),
  }, { pretty = true })
end

--- `cosmic bom [--licenses | --json <path>]`: what the running binary's
--- own database says it is made of. Nothing is built or staged here:
--- `build/dispatch.tl` has a tool older than cosmic's own tree rebuild
--- itself first, since `build.reboot` requires this module through
--- `build.writer`.
function bom.run(argv: {integer:string}): integer
  local started = Time.monotonic_ns()
  local function finish(code: integer, detail: string): integer
    log:verdict("bom", code == 0, detail .. ", " .. clock.elapsed_ms(started) .. " ms")
    return code
  end
  local usage = "cosmic bom [--licenses | --json <path>]"
  local parsed, parse_trouble = Flags.parse(argv, 2, Cli.options.bom)
  if parsed == nil then
    log:complain("bom: " .. parse_trouble .. "; " .. usage)
    return finish(2, "usage: see `cosmic help bom`")
  end
  if #parsed.words > 0 or #parsed.given > 1 then
    log:complain("bom: takes one option at most, and no words: " .. usage)
    return finish(2, "usage: see `cosmic help bom`")
  end
  local databases = Store.databases()
  local binary = databases[#databases]
  if binary == nil then
    log:complain("bom: the running artifact has no database")
    return finish(1, "no database")
  end
  local rows, trouble = bom.rows(binary)
  if rows == nil then
    log:complain("bom: " .. trouble)
    return finish(1, "the binary's own database")
  end
  if parsed.set["--licenses"] then
    local notices, notice_trouble = bom.notices(binary)
    if notices == nil then
      log:complain("bom: " .. notice_trouble)
      return finish(1, "the binary's own database")
    end
    log:say(notices)
    return finish(0, #rows .. " components")
  end
  local path = parsed.values["--json"]
  if path ~= nil then
    local document, encode_trouble = bom.cyclonedx(rows, "cosmic", Store.meta("boot_hash") or "")
    if document == nil then
      log:complain("bom: " .. encode_trouble)
      return finish(1, "encoding")
    end
    local written, write_trouble = Fs.write(path, document .. "\n")
    if not written then
      log:complain("bom: " .. path .. ": " .. write_trouble)
      return finish(1, path)
    end
    return finish(0, #rows .. " components written to " .. path)
  end
  for _, line in ipairs(lines_of(rows)) do
    log:say(line)
  end
  return finish(0, #rows .. " components")
end

return bom
