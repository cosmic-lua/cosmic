--- The files that stay Teal when the translated tree is committed (doc/plans/strict-teal.md, "the switch"): a
--- release pinned in [`ci/cosmic-driver.pin`] parses them, and it reads Teal until the pin moves past the
--- switch. The list itself is [`ci/islands.txt`], which the CI driver's `check-islands` reads to type-check them
--- on that release; this module holds what the tree knows of them. `ci/` is compiled by the CI driver on that
--- release; the bootstrap scripts are run standalone on it by [`bin/cosmic-bootstrap`] ([`bin/zig`], [`bin/vendor`],
--- [`bin/verify-codesign`], [`bin/perf`], and [`bin/cosmic`] for [`build/paths.tl`]). The new checker's own source is not one: `cosmic compile --grammar new`
--- ([`build/compile.tl`]) reads the new grammar, so the pin moves before the switch.
---
--- `ci/` is a project of its own that nothing outside it requires, so only the pinned release reads it. The
--- files of `build/` are also modules of the tree: [`build/paths.tl`] is required by about twenty modules,
--- [`build/zig.tl`] by [`build/c/init.tl`], [`build/vendor.tl`] by [`build/refresh.tl`] and [`build/perf.tl`] by
--- [`build/perf_validation.tl`]. After the switch the tool reads every module in the new grammar, so these are
--- written, as far as the two grammars have a common spelling, in the subset both parsers read: `blocked`
--- counts what has none, by file, and a test holds each file to it.
local Fs = require("cosmic.fs")

local record Islands
  --- Whether the file `file` is an island of the checkout it lies in: the nearest directory above it that holds
  --- [`ci/islands.txt`] lists it, by its path below that directory, or a directory above it ("ci/"). A file outside any
  --- such checkout is none. The tool reads a source it runs standalone in the new grammar unless it is one
  --- ([`build.standalone`]).
  holds: function(file: string): boolean

  --- For each file of `build/` in [`ci/islands.txt`], the forms the new grammar refuses that the pinned release
  --- needs, with how many of each (a lexer or parser code). A file with none is written in the common subset. A
  --- count only falls.
  ---
  --- `nil_union`: `T | nil` has no spelling the fork also reads (`T?` is the new grammar's alone). `metamethod`:
  --- `metamethod __close` has none either (a plain `__close` field is a type error in the fork for a `<close>`
  --- local).
  blocked: {string: {string: integer}}
end

--- Whether the list `text` ([`ci/islands.txt`]: one path a line, what a `#` starts and blank lines left out) names `relative`,
--- itself or a directory above it.
local function listed(text: string, relative: string): boolean
  for line in text:gmatch("[^\n]+") do
    local path = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if path == relative or (path:sub(-1) == "/" and relative:sub(1, #path) == path) then
      return true
    end
  end
  return false
end

local function holds(file: string): boolean
  local absolute, _ = Fs.absolute(file)
  if absolute == nil then
    return false
  end
  local directory = Fs.dirname(absolute)
  while true do
    local text, _ = Fs.read(directory .. "/ci/islands.txt")
    if text ~= nil then
      return listed(text, absolute:sub(#directory + 2))
    end
    local parent = Fs.dirname(directory)
    if parent == directory or parent == "" then
      return false
    end
    directory = parent
  end
end

local islands: Islands = {
  holds = holds,
  blocked = {
    ["build/paths.tl"] = { nil_union = 4 },
    ["build/perf.tl"] = { nil_union = 9 },
    ["build/vendor.tl"] = { nil_union = 11 },
    ["build/zig.tl"] = { metamethod = 1, nil_union = 20 },
  },
}

return islands
