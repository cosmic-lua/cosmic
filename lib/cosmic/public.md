# public

 The PUBLIC module manifest: the single source of truth for which
 top-level cosmic.* modules are supported, documented API surface.

 Every requireable name directly under cosmic.* must appear in exactly
 one of the two lists below; public_test.tl enumerates the modules
 embedded in the binary and fails when one is missing or stale.
 Internal modules are implementation shards: they can change or
 disappear without notice, so user code must not require them.

## Types

### PublicModule

```teal
local record PublicModule
  public: {string}
  internal: {string}
end
```
