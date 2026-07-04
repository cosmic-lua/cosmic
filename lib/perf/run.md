# run

## Types

### Args

```teal
local record Args
  out: string
  samples: integer
  min_secs: number
  only: string
  compare_mode: boolean
  threshold: number
  help: boolean
  positional: {string}
  err: string
end
```

### run

```teal
local record run
  main: function(...: string): integer
  parse_args: function(argv: {string}): Args
  collect_meta: function(samples: integer, min_secs: number): pt.Meta
  load_module: function(name: string): pt.BenchModule, string
end
```
