## Change

Give `lsqlite3` a per-connection extension registration entry point, so a caller can
ask for an extension by name.

Today registration is one hardcoded call in the open path
(`tool/net/lsqlite3.c:2413`, `sqlite3_zipfile_init(db->db, 0, 0)`), which registers
`zipfile` on every connection and offers no way to ask for anything else. With the
registry from the extraction item in place, expose it:

- a Lua-callable entry that takes an extension name and registers it on that
  connection, returning success or a message naming what was refused;
- a way to enumerate the registry's names, so the caller can discover what this
  build carries rather than guessing from a version number.

Both matter for a fat binary: the same cosmic release may be built with different
flag sets, so "what can this connection do" is a runtime question, not a
compile-time constant a caller can assume.

### The contract the cosmic side needs

The cosmic API is *ensure this capability is available on this connection, or
fail*. That means the C side must distinguish, in its return, between:

- registered successfully;
- **already present** — a compile-time feature such as FTS5, which cannot be
  registered and does not need to be. `pragma_module_list` is how presence is
  currently checked (`cosmic/sqlite/zipfile_test.tl` uses exactly that query);
- not available in this build — the caller asked for something this binary does not
  carry, which must be a loud failure rather than a silent no-op.

Those three outcomes are the whole reason the cosmic option can have one meaning
for two mechanisms; collapsing them into a boolean pushes the distinction back to
the caller and defeats the design.

Gate: `make -j$(nproc) o//tool/lua/test`, with cases for each of the three
outcomes.

## Non-goals

- No change to which extensions are registered by default; that is the cosmic
  item's decision and this item leaves the existing `zipfile` call alone.
- No extraction work — this item consumes the registry, it does not build it.
- No UDF changes.
