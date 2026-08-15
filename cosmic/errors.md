# errors

 The one sink-side supertype for structured errors.

 Errors are strings by default. A module whose failures carry real
 structure returns its OWN concrete record in slot 2 — `local record
 Error is errors.Failure` plus the typed fields its domain needs
 (`fetch.Error`'s `kind`) — and this interface is what a SINK that
 accepts any module's error names: `check.must` widens its slot 2 to
 `string | Failure`. Teal admits at most one table type in a union,
 so there can be exactly one such supertype; this is it, declared
 low so `cosmic.check` can reference it without depending on any
 producing module.

 Classification is by FIELD value, never by `is` on a concrete
 record: `is` compiles to `type(x) == "table"`, so narrowing from
 Failure to a concrete record is unsound. Producers attach a
 metatable whose `__tostring` renders the classified message —
 `__concat` is deliberately NOT declared, so `"x: " .. err` is a
 compile error; write `tostring(err)` or read `.message`. A module
 that needs to carry another module's structured failure translates
 it into its own error type at the boundary (the union rule forbids
 naming two concrete records in one slot).

## Types

### ErrorsModule
