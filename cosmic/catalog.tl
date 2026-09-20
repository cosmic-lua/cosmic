--- Bridges cosmic's own errno guidance into the reactive path an
--- uncaught error's own message can match (`core/main.c`'s
--- `catalog_guidance`).
---
--- Nothing here duplicates a hint: every row's `text` is left for
--- `catalog_guidance`'s own SQL to fill in by joining `module`/
--- `symbol` back to a real doc comment -- `cosmic/errno.tl`'s own
--- `Errno` record, the same one `cosmic docs ENOENT` already finds
--- directly. A word that never needs reactive matching -- a removed
--- global, a verb, cosmic's own vocabulary -- carries no row here at
--- all: it is a plain doc comment `cosmic docs` finds by name
--- already, with no bridge required (see `cosmic/removed.tl`,
--- `cosmic/glossary.tl`).
local Errno = require("cosmic.errno")

local record Catalog
  --- One row: the message `catalog_guidance` matches an uncaught
  --- error against, and the real doc-commented symbol (`module`,
  --- `symbol`) whose text answers for it.
  record Row
    module: string
    symbol: string
    message: string
    file: string
    line: integer
  end

  rows: {Row}
end

--- One row per `cosmic/errno.tl` field, spelled out (not looped over
--- `pairs(Errno)`, which has no guaranteed order and a rebuild must
--- be byte-identical): `message` is that field's own value, the
--- exact `strerror()` text it stands for.
Catalog.rows = {
  { module = "cosmic.errno", symbol = "Errno.ENOENT", message = Errno.ENOENT,
    file = "cosmic/errno.tl", line = 0 },
  { module = "cosmic.errno", symbol = "Errno.EACCES", message = Errno.EACCES,
    file = "cosmic/errno.tl", line = 0 },
  { module = "cosmic.errno", symbol = "Errno.EEXIST", message = Errno.EEXIST,
    file = "cosmic/errno.tl", line = 0 },
  { module = "cosmic.errno", symbol = "Errno.ENOTDIR", message = Errno.ENOTDIR,
    file = "cosmic/errno.tl", line = 0 },
  { module = "cosmic.errno", symbol = "Errno.EISDIR", message = Errno.EISDIR,
    file = "cosmic/errno.tl", line = 0 },
  { module = "cosmic.errno", symbol = "Errno.ENOSPC", message = Errno.ENOSPC,
    file = "cosmic/errno.tl", line = 0 },
  { module = "cosmic.errno", symbol = "Errno.EMFILE", message = Errno.EMFILE,
    file = "cosmic/errno.tl", line = 0 },
}

return Catalog
