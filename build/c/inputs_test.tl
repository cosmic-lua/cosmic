--- The key of a C file's inputs ([`build.c.inputs`]): it changes with anything a compile reads, so that a memo kept under
--- it never serves what an older input made, and it is nil where the includes cannot be read from text.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local inputs = require("build.c.inputs")

Test.policy{ cpu_features = true }

--- Writes `files` (by name) under `dir`.
local function write(dir: string, files: {string: string})
  for name, text in pairs(files) do
    assert(Fs.mkdirs(Fs.dirname(dir .. "/" .. name)))
    assert(Fs.write(dir .. "/" .. name, text))
  end
end

--- The key of `dir`/main.c searching `include` and then `later` (directories of `dir`), with the command's `extra` words.
local function key_of(dir: string, extra?: {string}, dirs?: {string}): string?
  local searched: mut {string} = {}
  for _, d in ipairs(dirs or { "inc" }) do searched[#searched + 1] = dir .. "/" .. d end
  local words: mut {string} = { "cc", "-c", "main.c" }
  for _, w in ipairs(extra or {}) do words[#words + 1] = w end
  return inputs.key(inputs.reader(searched, words), dir .. "/main.c", words, "zig-1")
end

local function test_a_key_is_the_same_for_the_same_inputs(tmp: string)
  write(tmp, { ["main.c"] = '#include "a.h"\nint main(void) { return 0; }\n', ["a.h"] = "int a;\n" })
  local first = key_of(tmp)
  assert(first ~= nil)
  assert(first == key_of(tmp))
end

local function test_a_changed_header_changes_the_key_however_deep(tmp: string)
  write(tmp, { ["main.c"] = '#include "a.h"\n', ["a.h"] = '#include <b.h>\n', ["inc/b.h"] = '#include "c.h"\n',
    ["inc/c.h"] = "int c;\n" })
  local before = key_of(tmp)
  assert(before ~= nil)
  write(tmp, { ["inc/c.h"] = "int c2;\n" })
  assert(key_of(tmp) ~= before, "a header three includes down did not change the key")
  write(tmp, { ["inc/c.h"] = "int c;\n" })
  assert(key_of(tmp) == before)
  write(tmp, { ["main.c"] = '#include "a.h"\nint x;\n' })
  assert(key_of(tmp) ~= before, "the file's own text did not change the key")
end

local function test_a_file_nothing_includes_does_not_change_the_key(tmp: string)
  write(tmp, { ["main.c"] = '#include "a.h"\n', ["a.h"] = "int a;\n", ["other.h"] = "int other;\n" })
  local before = key_of(tmp)
  assert(before ~= nil)
  write(tmp, { ["other.h"] = "int other2;\n" })
  assert(key_of(tmp) == before)
end

local function test_a_header_found_earlier_in_the_search_changes_the_key(tmp: string)
  write(tmp, { ["main.c"] = "#include <h.h>\n", ["late/h.h"] = "int late;\n" })
  local before = key_of(tmp, nil, { "early", "late" })
  assert(before ~= nil)
  write(tmp, { ["early/h.h"] = "int early;\n" })
  assert(key_of(tmp, nil, { "early", "late" }) ~= before, "a header that now shadows another did not change the key")
end

local function test_a_copy_of_a_header_found_earlier_changes_the_key_though_its_bytes_are_the_same(tmp: string)
  -- The tree a compile prints names the file each declaration is in, so a header found at another path is another answer.
  write(tmp, { ["main.c"] = "#include <h.h>\n", ["late/h.h"] = "int h;\n" })
  local before = key_of(tmp, nil, { "early", "late" })
  assert(before ~= nil)
  write(tmp, { ["early/h.h"] = "int h;\n" })
  assert(key_of(tmp, nil, { "early", "late" }) ~= before, "a copy that now shadows the header did not change the key")
end

local function test_a_header_beside_the_includer_shadows_a_searched_one(tmp: string)
  write(tmp, { ["main.c"] = '#include "sub/a.h"\n', ["sub/a.h"] = '#include "h.h"\n', ["inc/h.h"] = "int far;\n" })
  local before = key_of(tmp)
  assert(before ~= nil)
  write(tmp, { ["sub/h.h"] = "int near;\n" })
  assert(key_of(tmp) ~= before, "a header beside the includer did not change the key")
end

local function test_a_name_found_nowhere_is_the_compilers_and_held_by_name(tmp: string)
  write(tmp, { ["main.c"] = "#include <stdint.h>\n" })
  local a = key_of(tmp)
  assert(a ~= nil)
  write(tmp, { ["main.c"] = "#include <stddef.h>\n" })
  assert(key_of(tmp) ~= a)
  write(tmp, { ["main.c"] = "#include <stdint.h>\n" })
  assert(inputs.key(inputs.reader({ tmp .. "/inc" }, { "cc" }), tmp .. "/main.c", { "cc" }, "zig-2") ~=
      inputs.key(inputs.reader({ tmp .. "/inc" }, { "cc" }), tmp .. "/main.c", { "cc" }, "zig-1"),
    "the compiler's install is not in the key")
end

local function test_the_command_is_in_the_key(tmp: string)
  write(tmp, { ["main.c"] = "int a;\n" })
  assert(key_of(tmp, { "-DA=1" }) ~= key_of(tmp, { "-DA=2" }))
end

local function test_a_macro_include_reads_the_string_the_command_defines(tmp: string)
  write(tmp, { ["main.c"] = "#include CONFIG\n", ["inc/one.h"] = "int one;\n", ["inc/two.h"] = "int two;\n" })
  local one = key_of(tmp, { '-DCONFIG="one.h"' })
  local two = key_of(tmp, { '-DCONFIG="two.h"' })
  assert(one ~= nil and two ~= nil and one ~= two)
  write(tmp, { ["inc/one.h"] = "int one2;\n" })
  assert(key_of(tmp, { '-DCONFIG="one.h"' }) ~= one, "a header named by a macro did not change the key")
end

local function test_a_macro_include_reads_a_string_a_header_defines(tmp: string)
  write(tmp, { ["main.c"] = '#include "cfg.h"\n#include PICKED\n', ["cfg.h"] = '#define PICKED "p.h"\n',
    ["p.h"] = "int p;\n" })
  local before = key_of(tmp, nil, { "." })
  assert(before ~= nil)
  write(tmp, { ["p.h"] = "int p2;\n" })
  assert(key_of(tmp, nil, { "." }) ~= before, "a header named by a macro a header defines did not change the key")
end

local function test_a_macro_defined_nowhere_names_no_header(tmp: string)
  write(tmp, { ["main.c"] = "#include MISSING\n" })
  assert(key_of(tmp) ~= nil)
  -- Defining it later, in the command, changes what is read.
  write(tmp, { ["inc/m.h"] = "int m;\n" })
  assert(key_of(tmp, { '-DMISSING="m.h"' }) ~= key_of(tmp))
end

local function test_a_macro_defined_as_more_than_a_name_is_not_keyed(tmp: string)
  write(tmp, { ["main.c"] = "#include PICKED\n" })
  assert(key_of(tmp, { "-DPICKED=1+1" }) == nil)
end

local function test_where_the_includes_cannot_be_read_there_is_no_key(tmp: string)
  for _, text in ipairs({ "#include_next <a.h>\n", "#import <a.h>\n", "#include FN(x)\n", "%:include <a.h>\n",
      "??=include <a.h>\n", "#/**/include <a.h>\n", "const char *d = __DATE__;\n", "int x = __has_include(FOO);\n" }) do
    write(tmp, { ["main.c"] = text })
    assert(key_of(tmp) == nil, "a key was made over " .. text)
  end
  write(tmp, { ["main.c"] = '#include "gone.h"\n#include "a.h"\n', ["a.h"] = '#include_next <x.h>\n' })
  assert(key_of(tmp) == nil, "an include_next in a header did not stop the key")
end

local function test_a_has_include_of_a_name_is_held_by_where_it_is_found(tmp: string)
  write(tmp, { ["main.c"] = "#if __has_include(<opt.h>)\nint have;\n#endif\n" })
  local without = key_of(tmp)
  assert(without ~= nil)
  write(tmp, { ["inc/opt.h"] = "int opt;\n" })
  assert(key_of(tmp) ~= without, "a header that now exists did not change a has_include's key")
end

local function test_a_backslash_continued_directive_is_one_line(tmp: string)
  write(tmp, { ["main.c"] = '#  \\\ninclude "a.h"\n', ["a.h"] = "int a;\n" })
  local before = key_of(tmp)
  assert(before ~= nil)
  write(tmp, { ["a.h"] = "int b;\n" })
  assert(key_of(tmp) ~= before)
end
