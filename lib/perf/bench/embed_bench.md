# embed_bench

 Embed/extract scenarios: exercises cosmic.embed's directory walk
 (collect_dir) and zip-to-disk unpack (extract) against a real tree of
 directories and files, using the cosmic binary under test as the
 source executable.

## Types

### EmbedResult

```teal
local record EmbedResult
  ok: boolean
  message: string
  file_count: integer
end
```
