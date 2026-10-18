--- The files that stay Teal when the translated tree is committed (doc/plans/strict-teal.md, "the switch"): a
--- release pinned in [`ci/cosmic-driver.pin`] parses them, and it reads Teal until the pin moves past the
--- switch. `ci/` is compiled by the CI driver on that release; the bootstrap scripts are run standalone on it
--- by [`bin/cosmic-bootstrap`] ([`bin/zig`], [`bin/vendor`], [`bin/verify-codesign`], [`bin/perf`], and
--- [`bin/cosmic`] for [`build/paths.tl`]). The new checker's own source is not one: `cosmic compile --grammar new`
--- ([`build/compile.tl`]) reads the new grammar, so the pin moves before the switch.
---
--- `ci/` is a project of its own that nothing outside it requires, so only the pinned release reads it. The
--- files of `build/` are also modules of the tree: [`build/paths.tl`] is required by about twenty modules,
--- [`build/zig.tl`] by [`build/c/init.tl`], [`build/vendor.tl`] by [`build/refresh.tl`] and [`build/perf.tl`] by
--- [`build/perf_validation.tl`]. After the switch the tool reads every module in the new grammar, so these are
--- written, as far as the two grammars have a common spelling, in the subset both parsers read: `blocked`
--- counts what has none, by file, and a test holds each file to it. Nothing reads the list yet.
local record Islands
  --- The paths from the root of the tree, a directory ending in "/", in the order of their bytes.
  list: {string}

  --- For each file of `build/` in `list`, the forms the new grammar refuses that the pinned release needs, with
  --- how many of each (a lexer or parser code). A file with none is written in the common subset. A count only
  --- falls.
  ---
  --- `nil_union`: `T | nil` has no spelling the fork also reads (`T?` is the new grammar's alone). `metamethod`:
  --- `metamethod __close` has none either (a plain `__close` field is a type error in the fork for a `<close>`
  --- local).
  blocked: {string: {string: integer}}
end

local islands: Islands = {
  list = {
    "build/paths.tl",
    "build/perf.tl",
    "build/vendor.tl",
    "build/verify_codesign.tl",
    "build/zig.tl",
    "ci/",
  },
  blocked = {
    ["build/paths.tl"] = { nil_union = 4 },
    ["build/perf.tl"] = { nil_union = 9 },
    ["build/vendor.tl"] = { nil_union = 11 },
    ["build/zig.tl"] = { metamethod = 1, nil_union = 21 },
  },
}

return islands
