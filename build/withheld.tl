--- The globals and fields of `package` cosmic's runtime removes, which the checker withholds from a program so that it
--- refuses a use of one as the runtime would fail it ([`build.tree_program`]'s `globals`).
---
--- They are spelled here, not read from [`cosmic.removed`], so that what a compile accepts is decided by this module alone,
--- which the compiler's identity holds ([`build.identity`]), and an edit to the rest of the catalog -- the replacements a
--- refusal quotes -- compiles nothing again. build/withheld_test.tl holds them to the catalog's.

local record withheld
  --- The globals cosmic's runtime removes: [`cosmic.removed`]'s `order`.
  mut globals: {string}
  --- The fields of `package` the runtime removes ([`core/surface.c`]'s `clear_field` calls): [`cosmic.removed`]'s
  --- `package_fields`.
  mut package_fields: {string}
end

withheld.globals = { "io", "os", "debug", "dofile", "loadfile" }
withheld.package_fields = { "path", "cpath", "loadlib", "searchpath" }

return withheld
